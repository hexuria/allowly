import Foundation
import ApplicationServices
import AppKit
import JevCore

/// Callback for when a new dialog is detected.
public typealias DialogDetectedCallback = (ApprovalRequest) -> Void

/// Global registry to hold observers and their watchers
private var dialogWatcherRegistry: [pid_t: (watcher: DialogWatcher, observer: AXObserver)] = [:]
private let registryLock = NSLock()

/// Static callback function for AXObserver
private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) -> Void {
    guard let notificationStr = notification as String? else { return }

    // Find the watcher for this observer
    registryLock.lock()
    let watcher = dialogWatcherRegistry.values.first { $0.observer === observer }?.watcher
    registryLock.unlock()

    guard let watcher = watcher else { return }

    // Handle the notification asynchronously on the main thread
    DispatchQueue.main.async {
        Task {
            await watcher.handleNotificationAsync(element: element, notification: notificationStr)
        }
    }
}

/// DialogWatcher observes the system for newly-appearing modal dialogs and sheets.
/// It uses AXObserver to watch for window creation and focus changes.
public actor DialogWatcher: Sendable {
    /// Where to report what the watcher is doing. Without this the watcher was
    /// a black box: it logged "Watching for dialogs" from the caller and had
    /// no way to say that it had in fact attached to nothing.
    public nonisolated(unsafe) static var log: (@Sendable (String) -> Void)?
    private static func note(_ message: String) { log?("[watcher] \(message)") }

    private let callback: DialogDetectedCallback
    private let serialiser: DialogSerialiser
    private var observedApps: Set<pid_t> = []
    private var appMonitor: NSObjectProtocol?
    private var activationMonitor: NSObjectProtocol?
    private var terminationMonitor: NSObjectProtocol?
    private var sweepTask: Task<Void, Never>?

    /// Processes whose retry ladder ran out, and when.
    ///
    /// Without this the sweep made giving up unreachable: it offered
    /// every unwatched pid again every 5 seconds, each one starting a
    /// fresh 12-second ladder that ended in another "gave up" line.
    /// Measured on this Mac — 14 stock background agents
    /// (`Dock`, `WindowManager`, `universalaccessd`, widget extensions…)
    /// answer `AXObserverAddNotification` with -25204/-25207/-25208
    /// permanently, so steady state was 14 log lines every 5 seconds,
    /// about 25 MB a day, in the one file the README tells you to tail.
    ///
    /// Not permanent, because a process CAN gain a UI later than the
    /// ladder is willing to wait. It is simply tried far less often.
    private var gaveUp: [pid_t: Date] = [:]
    private static let retryAfterGivingUp: TimeInterval = 600

    // Role constants that cannot be imported directly
    private static let kAXDialogRole = "AXDialog"
    private static let kAXSheetRole = "AXSheet"

    /// Fired for EVERY focus or window-created event, dialog or not, with the
    /// owning pid. This watcher registers `kAXFocusedWindowChanged` for every
    /// running app and then discarded the event unless the new window was a
    /// dialog — which is exactly the signal a live model of "what is in
    /// front" needs. Nothing about the registration changes; the event is
    /// simply no longer thrown away.
    nonisolated(unsafe) public static var onFocusChanged: (@Sendable (pid_t, String) -> Void)?
    /// Fired when an app launches, activates or exits.
    nonisolated(unsafe) public static var onAppsChanged: (@Sendable () -> Void)?

    public init(onDialogDetected: @escaping DialogDetectedCallback) {
        self.callback = onDialogDetected
        self.serialiser = DialogSerialiser()
    }

    /// Start watching for dialogs. Must be called on the main thread.
    public nonisolated func start() {
        DispatchQueue.main.async { [weak self] in
            Task {
                await self?.startInternal()
            }
        }
    }

    /// Stop watching for dialogs. Must be called on the main thread.
    public nonisolated func stop() {
        DispatchQueue.main.async { [weak self] in
            Task {
                await self?.stopInternal()
            }
        }
    }

    private func startInternal() {
        // Check if we have Accessibility permission
        guard AccessibilityPermission.isTrusted() else {
            Self.note("not trusted for accessibility — watching nothing")
            return
        }

        // Register observers for currently running applications
        for app in NSWorkspace.shared.runningApplications {
            guard let pid = app.processIdentifier as pid_t? else { continue }
            registerObserver(for: pid, app: app)
        }

        // Monitor for new application launches, and for apps coming forward.
        // Registration is idempotent.
        //
        // These are a FAST PATH, not the mechanism. Correctness comes
        // from the sweep below, because the notifications cannot be
        // relied on: measured, a bundle-less executable that calls
        // `setActivationPolicy(.accessory)` and puts up a modal alert
        // posts neither `didLaunchApplication` nor
        // `didActivateApplication`, and neither does a properly bundled
        // `LSUIElement` agent. Those apps were invisible to jev
        // entirely — no card, no push, no log line.
        let workspace = NSWorkspace.shared
        let register: @Sendable (Notification) -> Void = { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Self.onAppsChanged?()
            Task { await self?.registerObserver(for: pid, app: app) }
        }
        Self.note("attached to \(observedApps.count) running apps")
        appMonitor = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main, using: register)
        activationMonitor = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main, using: register)

        // …and forget an app when it exits.
        //
        // `registerObserver` returns early for a pid already in
        // `observedApps`, and nothing ever removed one. macOS reuses
        // pids, so on a daemon left up for days a new app could inherit
        // the pid of a dead one, be treated as already watched, and
        // have its dialogs silently never reach the phone.
        terminationMonitor = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Self.onAppsChanged?()
                Task { await self?.forgetObserver(for: pid) }
            }

        // Reconcile, on a timer, and stop depending on being told.
        //
        // This is what actually guarantees an app gets watched. Two
        // separate measured failures both end here: an app that posts no
        // launch notification is never offered to `registerObserver` at
        // all, and an app that IS offered in the first ~100 ms of its
        // life fails both AX subscriptions because its accessibility
        // connection does not exist yet. Retries fix the second; only a
        // sweep fixes the first.
        //
        // A set difference over `runningApplications` every few seconds
        // is cheap next to being blind to Chrome.
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.reconcileRunningApps()
            }
        }
    }

    /// Register anything running that is not being watched yet.
    private func reconcileRunningApps() {
        guard AccessibilityPermission.isTrusted() else { return }
        // Reap the dead FIRST, by asking the kernel rather than waiting
        // to be told.
        //
        // `forgetObserver` was wired only to `didTerminateApplication`,
        // and measured: a bundle-less `.accessory` executable and a
        // bundled `LSUIElement` agent post no terminate notification
        // either — 6 of 6 short-lived accessory agents stayed in the
        // tracked set after exiting. So `observedApps`,
        // `dialogWatcherRegistry` and `gaveUp` grew for the life of the
        // daemon, each dead entry still holding an `AXObserver` and its
        // run loop source.
        //
        // The leak is the smaller half. pids get reused — measured at
        // 259 new pids in 30 seconds on this Mac, which wraps the pid
        // space in about three hours — and a live app inheriting a dead
        // app's pid was treated as already watched, so `registerObserver`
        // returned at its guard and that app's dialogs never reached the
        // phone again. Which is the exact thing the comment on
        // `forgetObserver` says it exists to prevent.
        for pid in observedApps where !Self.isAlive(pid) { forgetObserver(for: pid) }
        for pid in gaveUp.keys where !Self.isAlive(pid) { gaveUp.removeValue(forKey: pid) }

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0, !observedApps.contains(pid), !app.isTerminated else { continue }
            if let when = gaveUp[pid],
               Date().timeIntervalSince(when) < Self.retryAfterGivingUp { continue }
            registerObserver(for: pid, app: app)
        }
    }

    /// What the watcher currently believes it is watching.
    ///
    /// Exposed so the reap can be measured rather than argued about:
    /// nothing dead should survive two sweeps.
    public var watchedPids: Set<pid_t> { observedApps }
    public var watchedCount: Int { observedApps.count }

    /// Is this process still running?
    ///
    /// `kill(pid, 0)` and nothing else: `NSRunningApplication` is not a
    /// liveness oracle (it answers nil for plenty of live processes),
    /// and `runningApplications` only lists session apps. `EPERM` means
    /// alive and not ours; only `ESRCH` means gone.
    private static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Try this app again shortly, because AX was not ready for it yet.
    private func retryRegistration(pid: pid_t, app: NSRunningApplication,
                                   attempt: Int, why: String) {
        guard attempt < Self.registrationRetries.count else {
            // Once per process, not once per sweep.
            if gaveUp[pid] == nil {
                Self.note("gave up watching \(app.localizedName ?? "pid \(pid)") — \(why)")
            }
            gaveUp[pid] = Date()
            return
        }
        let delay = Self.registrationRetries[attempt]
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !app.isTerminated else { return }
            await self.registerObserver(for: pid, app: app, attempt: attempt + 1)
        }
    }

    /// Drop everything held for a process that has gone.
    private func forgetObserver(for pid: pid_t) {
        // …including any record that we stopped trying: a reused pid is
        // a different process and deserves a fresh chance.
        gaveUp.removeValue(forKey: pid)
        guard observedApps.contains(pid) else { return }
        observedApps.remove(pid)
        registryLock.lock()
        let entry = dialogWatcherRegistry.removeValue(forKey: pid)
        registryLock.unlock()
        if let observer = entry?.observer {
            // `.commonModes`, matching the mode it was ADDED in. Removing
            // it from `.defaultMode` left the source attached — measured:
            // `CFRunLoopContainsSource(rl, src, .commonModes)` still true
            // afterwards — so the run loop kept a source whose observer
            // had just lost its only strong reference.
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .commonModes)
        }
        Self.note("forgot \(pid) — it exited")
    }

    private func stopInternal() {
        for monitor in [appMonitor, activationMonitor, terminationMonitor].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(monitor)
        }
        appMonitor = nil
        activationMonitor = nil
        terminationMonitor = nil
        sweepTask?.cancel()
        sweepTask = nil

        // Clean up observers, and take their run loop sources with them
        // — dropping the registry entry alone left each one attached to
        // the main run loop for the life of the process.
        registryLock.lock()
        for pid in observedApps {
            if let entry = dialogWatcherRegistry.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                      AXObserverGetRunLoopSource(entry.observer), .commonModes)
            }
        }
        registryLock.unlock()

        observedApps.removeAll()
    }

    /// How long to wait before trying an app again, and how many times.
    ///
    /// A process that has only just launched has no accessibility
    /// connection yet — for roughly the first tenth of a second
    /// `AXObserverAddNotification` answers `kAXErrorCannotComplete`. The
    /// window widens under load, so this backs off rather than sleeping
    /// a fixed amount, and gives up after about twelve seconds.
    private static let registrationRetries: [Duration] = [
        .milliseconds(120), .milliseconds(350), .seconds(1),
        .seconds(3), .seconds(8),
    ]

    /// Register an AXObserver for a specific application.
    ///
    /// The return values of `AXObserverAddNotification` are the whole
    /// point of this function and they were being discarded.
    ///
    /// What that cost: `didLaunchApplication` fires the instant a
    /// process appears, inside the window where AX is not ready, so both
    /// subscriptions failed with -25204. The pid went into
    /// `observedApps` anyway, which made the `didActivateApplication`
    /// re-registration — the one that exists precisely to catch this —
    /// return immediately at the guard above. `scanExistingWindows` ran
    /// at the same instant, when the app had no windows yet. The result
    /// was an observer subscribed to nothing, marked as watched, for the
    /// life of the process.
    ///
    /// Measured four ways, including end to end: start jevd, then open
    /// an app, raise a dialog — no card, no push, no log line. Only apps
    /// that were ALREADY running when jevd started were ever watched.
    /// For a daemon that starts at login, that is most of them.
    private func registerObserver(for pid: pid_t, app: NSRunningApplication, attempt: Int = 0) {
        guard !observedApps.contains(pid) else { return }

        let axApp = AXUIElementCreateApplication(pid)

        // Create observer
        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)

        guard result == .success, let observer = observer else {
            retryRegistration(pid: pid, app: app, attempt: attempt,
                              why: "AXObserverCreate \(result.rawValue)")
            return
        }

        // Register for window notifications, and BELIEVE THE ANSWER.
        let created = AXObserverAddNotification(
            observer, axApp, kAXWindowCreatedNotification as CFString, nil)
        let focused = AXObserverAddNotification(
            observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)
        guard created == .success, focused == .success else {
            // Nothing is registered and nothing is marked observed, so
            // the retry below — or a later activation — can try again.
            retryRegistration(pid: pid, app: app, attempt: attempt,
                              why: "addNotification \(created.rawValue)/\(focused.rawValue)")
            return
        }

        // Attach to the MAIN run loop, not the current one.
        //
        // This method is actor-isolated, so it runs on a cooperative-pool
        // thread whose run loop is never run — the source was being added to a
        // run loop that never spins, and no AX notification was ever delivered.
        // The dialog watcher reported that it was watching and saw nothing,
        // for any dialog, ever.
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           CFRunLoopMode.commonModes)

        // Register in global registry
        registryLock.lock()
        dialogWatcherRegistry[pid] = (watcher: self, observer: observer)
        registryLock.unlock()

        observedApps.insert(pid)

        // Sweep what is already open.
        //
        // Observing an app only tells us about windows created from now on,
        // and a process that becomes a UI app by putting a dialog on screen is
        // registered a beat *after* that dialog exists — so the one
        // notification that mattered was always already gone. The same sweep
        // catches a permission dialog that was sitting there before Jev
        // started.
        scanExistingWindows(of: axApp)
    }

    private func scanExistingWindows(of axApp: AXUIElement) {
        // An unresponsive app must not stall the watcher.
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        guard let windows = getAttribute(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return
        }
        for window in windows where isDialogElement(window) {
            processDialog(window)
        }
    }

    /// What the card is headed, and what it says underneath.
    ///
    /// Pure, and separated out for one reason: every attempt at this so far
    /// has been wrong in a way only a worked example shows. `serialize`
    /// opens with the role in brackets — and, when the dialog has a title,
    /// with the title appended to it: `[AXSheet] Close Tab?`. Testing for a
    /// "bare role marker" therefore did nothing on a titled dialog, so the
    /// card was headed `Close Tab?` above a body reading
    /// `[AXSheet] Close Tab?` then `Close Tab?` again — the same sentence
    /// three times, once with the role still on it.
    ///
    /// The header is the FIRST line and is always the serialiser's, so it
    /// goes by position rather than by shape.
    public static func heading(dialogText: String, axTitle: String,
                               appName: String) -> (title: String, body: String) {
        // Split on any newline, not just "\n".
        //
        // Swift treats "\r\n" as ONE grapheme, so `split(separator: "\n")`
        // does not divide it — a dialog whose AX text uses CRLF (Java, Qt
        // and Electron surfaces do) collapsed into a single line, which
        // then started with "[" and was removed whole as the header. The
        // card came out with the app's name and no body at all: approve
        // this thing I will not tell you about. The HTTP parser in this
        // same repo documents the identical trap.
        // `omittingEmptySubsequences: false`, so the header keeps its
        // place in the array even when the serialiser had nothing to put
        // on it. Dropping it silently is what made "by position" a lie:
        // the first line then became the first line of the BODY, and
        // `removeFirst` ate it. Blank lines are filtered out below anyway.
        var lines = dialogText
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // The serialiser's header is always the FIRST line, and `split`
        // above has not dropped anything, so take it by position rather
        // than by shape — testing `hasPrefix("[")` would eat a real body
        // line like "[Beta] This build expires tomorrow." whenever the
        // header itself came back empty.
        if !lines.isEmpty { lines.removeFirst() }

        // A button is not a heading. The card draws every option as a real
        // button already, so `BUTTON: Cancel` in the body is the same
        // information twice — and heading a card `BUTTON: Delete Group`
        // reads like an instruction, which is worse than `[AXSheet]`.
        let isButtonLine: (String) -> Bool = { $0.hasPrefix("BUTTON: ") }

        // Widget furniture is filtered by the SERIALISER, not here.
        //
        // It was filtered here, and `DialogSerialiser.serialize` decides
        // whether to fall back to the window's own description by asking
        // whether the walk produced any prose. The two tests disagreed:
        // a furniture line the serialiser kept made it skip the
        // fallback, and this filter then deleted that line, leaving a
        // card with no body under a live Delete button. Measured on
        // three shapes. One filter, in the place that can act on it.

        lines = lines.filter { !$0.isEmpty && !isButtonLine($0) }
        // Case-insensitively, because "Leave site?" and "leave site?" are
        // the same heading said twice.
        let sameAsTitle: (String, String) -> Bool = {
            $0.compare($1, options: .caseInsensitive) == .orderedSame
        }

        // An AXTitle that only names the widget is worse than no title.
        //
        // Measured on a live `NSAlert`: the window's AXTitle is
        // "liveholder.bin alert" — the process name plus the kind of
        // thing it is. Preferred over the body, that made the card read
        // "liveholder.bin alert" and the push read "TestApp —
        // TestApp alert", while the actual question sat in the body.
        // A real title ("Leave site?", "Unsaved changes") is still
        // preferred; this only steps aside for furniture.
        let axTitleSaysSomething: Bool = {
            let trimmed = axTitle.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return false }
            guard trimmed != appName.lowercased() else { return false }
            let widgets: Set<String> = ["alert", "dialog", "sheet", "window",
                                        "panel", "notification", "prompt"]
            if let last = trimmed.split(separator: " ").last,
               widgets.contains(String(last)) { return false }
            return true
        }()

        let title = ([axTitleSaysSomething ? axTitle : "", lines.first ?? "", appName]
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Dialog")
            .trimmingCharacters(in: .whitespaces)

        // Drop one leading repeat of the heading, not a run: a body that
        // legitimately opens with its own title twice keeps the second.
        var kept = lines
        if let first = kept.first, sameAsTitle(first, title) { kept.removeFirst() }
        return (title, kept.joined(separator: "\n"))
    }

    /// Handle a notification from an observer (async version).
    fileprivate func handleNotificationAsync(element: AXUIElement, notification: String) {
        if notification == kAXWindowCreatedNotification || notification == kAXFocusedWindowChangedNotification {
            var ownerPid: pid_t = 0
            if AXUIElementGetPid(element, &ownerPid) == .success {
                Self.onFocusChanged?(ownerPid, notification)
            }
        }
        // Check if this is a dialog/sheet we care about
        if notification == kAXWindowCreatedNotification || notification == kAXFocusedWindowChangedNotification {
            if isDialogElement(element) {
                processDialog(element)
            }
        }
    }

    /// Check if an element is a dialog or sheet we should handle.
    ///
    /// Matching on role alone missed almost everything. AppKit alerts, save and
    /// open panels, and the TCC consent sheets this product exists for are all
    /// role `AXWindow` carrying an `AXDialog`-family *subrole*; only a few are
    /// role `AXDialog` outright. The old check also treated a missing
    /// `AXModal` as modal but a present-and-false one as disqualifying, which
    /// dropped dialogs that are modal to their own app rather than the system.
    private func isDialogElement(_ element: AXUIElement) -> Bool {
        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String
        let subrole = getAttribute(element, kAXSubroleAttribute as CFString) as? String

        if role == Self.kAXDialogRole || role == Self.kAXSheetRole { return true }

        if role == "AXWindow", let subrole {
            return Self.dialogSubroles.contains(subrole)
        }
        return false
    }

    /// Deliberately narrow. `AXStandardWindow` is an ordinary window and
    /// `AXSystemFloatingWindow` covers HUDs like the volume overlay; including
    /// either would turn every window that opens into an approval.
    private static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    /// Process a detected dialog and create an ApprovalRequest.
    private func processDialog(_ element: AXUIElement) {
        // Attribute the dialog to the process that actually owns the element.
        // Policy keys on this bundle id, so taking it from anywhere else would let
        // one app's dialog inherit another app's allowlist entry.
        var bundleId = "unknown.bundle"
        var appName = "Unknown App"

        var ownerPid: pid_t = 0
        if AXUIElementGetPid(element, &ownerPid) == .success,
           let app = NSRunningApplication(processIdentifier: ownerPid) {
            bundleId = app.bundleIdentifier ?? "unknown.bundle"
            appName = app.localizedName ?? "Unknown App"
        }

        let appInfo = ApplicationInfo(
            name: appName,
            bundleIdentifier: bundleId
        )

        // Serialize the dialog
        let dialogText = serialiser.serialize(element: element, appName: appName)
        let buttons = serialiser.extractButtons(element: element)

        // Check for TCC, from what has already been read: neither the
        // wording nor the buttons decide this alone.
        let isTCC = TCCDetector.isTCCDialog(
            dialogText: dialogText, processName: bundleId, buttonTitles: buttons)

        // Extract title. Plenty of real dialogs carry no AXTitle at all, and a
        // card headed with an empty string tells you nothing about what you are
        // being asked to approve — so fall back to the first line of the dialog
        // itself, then to the app's name.
        let axTitle = (getAttribute(element, kAXTitleAttribute as CFString) as? String) ?? ""
        let (title, body) = Self.heading(dialogText: dialogText, axTitle: axTitle, appName: appName)

        // Create approval options from buttons
        // The option id is the button label, not a UUID: resolving an answer later
        // means finding this button by title in the live AX tree, and a random id
        // would be unmappable back to anything pressable.
        let options = buttons.map { button in
            ApprovalOption(
                id: button,
                label: button,
                riskLevel: Self.risk(forButtonLabel: button)
            )
        }

        // Nothing to ask about. Some background agents keep an AXDialog-subrole
        // window open permanently with no buttons at all; an approval with
        // nothing to press cannot be answered from the phone, so sending it is
        // noise. A TCC sheet is exempt: it is answered on the Mac itself.
        if !isTCC && options.isEmpty {
            return
        }

        // Create the approval request
        let requestId = UUID().uuidString
        let request = ApprovalRequest(
            id: requestId,
            kind: isTCC ? .tccConsent : .appDialog,
            title: title,
            bodyText: body,
            // Always a way out that presses nothing.
            //
            // A dialog card used to offer only the dialog's own buttons, so
            // the sole escape from one raised by mistake was the five-minute
            // expiry — and holding a live dialog open removed that. Safari's
            // address-bar panel reports as an AXDialog-subrole window with
            // two real AXButtons ("Edit", "Show Search Menu"); neither is an
            // answer to anything, and the card could not be got rid of.
            options: options + [ApprovalOption(id: "dismiss", label: "Dismiss",
                                               riskLevel: .low)],
            originatingApp: appInfo,
            timestamp: Date(),
            screenshotReference: nil,
            handoffOnly: isTCC
        )

        // Hold the live element so the button can still be pressed when the answer
        // comes back from the phone. The request itself goes over the wire and
        // cannot carry an AXUIElement.
        DialogRegistry.shared.register(id: requestId, element: element)

        // Deliver to callback
        callback(request)
    }

    /// Buttons that grant standing access or destroy data are high risk regardless
    /// of which app raised them, so policy can refuse to auto-press them.
    /// May a decision made without a person in the room press this?
    ///
    /// A POSITIVE list, which is the whole point. The rule used to be
    /// "anything not recognised as dangerous", and `risk`'s dangerous
    /// words are English — so on an en_GB Mac, measured against Apple's
    /// own Finder strings, `Move to Bin` and `Empty Bin` rated LOW and
    /// sat at the ceiling a remote decider may press unattended. So did
    /// `Löschen`, `Supprimer`, `Eliminar`, `Vider la corbeille` and
    /// `Nicht sichern`. A list of dangerous words can only ever be as
    /// long as the languages someone thought of; a list of SAFE words
    /// fails the other way, which is the way to fail.
    ///
    /// The localized half is the 42-language deny vocabulary already
    /// measured out of the system's own TCC table. Everything else is
    /// English, so on a non-English Mac a decider simply answers less
    /// and asks more. That is the cost, and it is the right cost.
    public static func isKnownSafeLabel(_ label: String) -> Bool {
        let l = label.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !l.isEmpty else { return false }
        if TCCDetector.isSystemDeny(label) { return true }
        // A safe word with something else bolted on is not a safe word.
        // `isKnownSafeLabel` is an exact match for exactly this reason:
        // "Cancel Subscription" is not "Cancel".
        // Only words that mean "do nothing" whatever the dialog is.
        //
        // These were on the list and are not that: "keep" is the
        // AFFIRMATIVE on a dangerous-download prompt (Chrome offers
        // [Discard] [Keep]); "close" discards in apps that name the
        // lose-changes button plainly; "stay" keeps a session alive on
        // a shared machine; "skip" and "ignore" skip verification. Each
        // is defensible in isolation, which is how they got here, and
        // none of them is safe in every dialog — which is the only
        // standard that matters for a press with nobody watching.
        let safe: Set<String> = [
            "cancel", "dismiss", "not now", "later", "no", "no thanks",
            "deny", "decline", "refuse", "reject",
            "keep editing", "go back", "remind me later", "ask me later",
        ]
        return safe.contains(l)
    }

    /// How much does pressing this cost if it was not what you meant?
    ///
    /// High is not "scary-sounding" — it is the gate. A high option asks
    /// "are you sure?" on the phone before anything is sent, and a
    /// spoken answer never acts on one without that. So the list has to
    /// hold everything that destroys work, not only everything that
    /// grants access.
    ///
    /// The losing-work half was missing entirely, and the voice path
    /// walked straight into it: "discard" is a refusal word, so on a
    /// "Discard Changes / Keep Editing" sheet a bare "no" resolved to
    /// Discard Changes, which rated LOW, which meant no confirmation —
    /// someone in the room saying "no" threw the work away and the phone
    /// reported it as sent. "Don't Save" was worse than low: it contains
    /// "save", so it rated MEDIUM off the affirmative list.
    ///
    /// Rating something high only ever costs one extra tap.
    public static func risk(forButtonLabel label: String) -> RiskLevel {
        // Curly apostrophe folded first — macOS types it, and "don\u{2019}t
        // save" does not contain "don't save".
        let l = label.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()

        // Putting something off does nothing, so it is never high. This
        // runs first because the words are matched by substring:
        // "Restart Later" contains "restart", and rating the DEFERRING
        // option of a "Restart / Restart Later" sheet exactly as high as
        // the acting one makes the badge stop telling you anything.
        // Spelled out rather than "anything containing later", because
        // "Send Later" still sends and "Delete and Keep Both" still
        // deletes — measured, both rated low under the loose rule.
        let deferrals = ["not now", "remind me", "ask me later", "keep editing",
                         "restart later", "install later", "update later",
                         "upgrade later", "download later", "try again later"]
        if l == "later" || deferrals.contains(where: { l.contains($0) }) { return .low }

        // A negation inverts the word after it, so the word alone
        // cannot carry the rating: "Don't Replace" keeps the file that
        // "Replace" would overwrite, and "Never Allow" is a standing
        // refusal. Declining used to rate HIGH while plain "Deny" rated
        // low — so the commonest sheet on macOS asked "are you sure?"
        // in order to say no, and nothing could ever auto-DECLINE
        // anything, because the decline button sat above the auto-press
        // ceiling.
        //
        // A rule, not a list. The list version held 21 phrases and
        // still missed "Don't Disable", "Don't Empty Trash",
        // "Don't Log Out", "Never Allow" and "Not Trusted" — a list of
        // negations can only ever be as long as someone remembered.
        let negations = ["don't ", "do not ", "never ", "not "]
        if let prefix = negations.first(where: { l.hasPrefix($0) }) {
            let rest = String(l.dropFirst(prefix.count))
            // …except the negations that still destroy something.
            // "Don't Save" loses the document, "Don't Restore" throws
            // away what was recovered, "Don't Keep" discards.
            // Exact, not a prefix. "Never Save Passwords" is the SAFE
            // button on Chrome's password prompt and rated high off the
            // prefix "save"; "Don't Save" and "Don't Save Changes" are
            // the ones that lose the document.
            let stillDestroys: Set<String> = [
                "save", "save changes", "save it", "save them",
                "restore", "keep", "keep changes",
            ]
            return stillDestroys.contains(rest) ? .high : .low
        }

        // Words that contain their own opposite: "disagree" contains
        // "agree", "unsubscribe" contains "subscribe". Removed before
        // the lists are consulted, rather than short-circuiting the
        // whole label — "Unsubscribe and Delete Account" and "Disagree
        // and Delete" were rated LOW by a short-circuit, and rated HIGH
        // by the substring they contain, depending on which check ran
        // first. Neither answer was about the word that matters.
        let plain = ["disagree", "unsubscribe"].reduce(l) {
            $0.replacingOccurrences(of: $1, with: " ")
        }

        let high = ["always allow", "allow", "trust", "delete", "erase", "send",
                    "purchase", "buy", "grant", "enable", "remove", "reset",
                    // …and everything that loses what you already had.
                    // ("don't save" and "don't restore" are handled by
                    // the negation rule above, not here.)
                    "discard", "revert", "overwrite", "replace",
                    "move to trash", "empty trash", "uninstall", "unpair",
                    "shut down", "restart", "log out", "sign out",
                    // "Close Without Saving" and "Quit Without Saving"
                    // lose the document as surely as "Don't Save" does,
                    // and "saving" does not contain "save".
                    "without saving", "leave site", "leave page",
                    "clear history", "forget this", "disable",
                    // …and everything that spends money or signs you up
                    // to something. Measured over 150 real macOS labels,
                    // every one of these rated LOW, which means no "are
                    // you sure?" and, worse, sitting at or below the
                    // ceiling a decider may press unattended. "Turn Off"
                    // is what macOS writes where this list said
                    // "Disable"; "Pay Now" is what a checkout sheet
                    // writes where it said "Purchase".
                    "pay", "subscribe", "confirm", "submit", "approve",
                    "authorize", "authorise", "accept", "agree", "turn off",
                    "turn on", "force quit", "quit anyway",
                    // en_GB macOS writes Bin where the US writes Trash,
                    // in a codebase that is itself British.
                    // "bin" and "trash" as whole words, because
                    // "Empty the Bin" defeats a two-word phrase and a
                    // definite article should not be a safety boundary.
                    "move to bin", "empty bin", "bin", "trash",
                    // A deliberately partial sample of the languages
                    // most likely to be in front of this, for the
                    // "are you sure?" gate. Auto-pressing no longer
                    // depends on this list being complete —
                    // `isKnownSafeLabel` does that — and it never can be.
                    "l\u{00F6}schen", "papierkorb", "nicht sichern",
                    "supprimer", "corbeille", "eliminar", "papelera",
                    "elimina", "cestino"]
        // Short terms match whole words, longer ones match anywhere.
        //
        // "ok" as a substring rated `Block Cookies`, `Look Up` and
        // `Add Bookmark` medium (measured), which put them above the
        // unattended ceiling while a French `Supprimer` sat below it.
        // Four characters is the line: "pay" must not match "Payment
        // Details", but "allow" should still match "Allow Once".
        func mentions(_ term: String) -> Bool {
            guard term.count <= 4, !term.contains(" ") else { return plain.contains(term) }
            return plain.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0 == term }
        }

        if high.contains(where: mentions) { return .high }
        // "okay" stopped matching when short terms went to whole words —
        // "ok" is not a word inside "okay" — so it silently lost its
        // badge. Spelled out rather than special-cased.
        let medium = ["ok", "okay", "continue", "yes", "install", "open", "save"]
        if medium.contains(where: mentions) { return .medium }
        return .low
    }

    /// Safely get an attribute from an AXUIElement.
    private func getAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }
}
