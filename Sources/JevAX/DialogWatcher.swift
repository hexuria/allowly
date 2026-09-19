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
    private let tccDetector: TCCDetector.Type = TCCDetector.self
    private var observedApps: Set<pid_t> = []
    private var appMonitor: NSObjectProtocol?
    private var activationMonitor: NSObjectProtocol?

    // Role constants that cannot be imported directly
    private static let kAXDialogRole = "AXDialog"
    private static let kAXSheetRole = "AXSheet"

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
        // A process that only becomes a UI app at the moment it shows a dialog
        // may never post didLaunch, so activation is watched too; registration
        // is idempotent.
        let workspace = NSWorkspace.shared
        let register: @Sendable (Notification) -> Void = { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Task { await self?.registerObserver(for: pid, app: app) }
        }
        Self.note("attached to \(observedApps.count) running apps")
        appMonitor = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main, using: register)
        activationMonitor = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main, using: register)
    }

    private func stopInternal() {
        for monitor in [appMonitor, activationMonitor].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(monitor)
        }
        appMonitor = nil
        activationMonitor = nil

        // Clean up observers
        registryLock.lock()
        for pid in observedApps {
            dialogWatcherRegistry.removeValue(forKey: pid)
        }
        registryLock.unlock()

        observedApps.removeAll()
    }

    /// Register an AXObserver for a specific application.
    private func registerObserver(for pid: pid_t, app: NSRunningApplication) {
        guard !observedApps.contains(pid) else { return }

        let axApp = AXUIElementCreateApplication(pid)

        // Create observer
        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)

        guard result == .success, let observer = observer else {
            Self.note("could not observe \(app.localizedName ?? "unknown"): \(result.rawValue)")
            return
        }

        // Register for window notifications
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, nil)
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)

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

    /// Handle a notification from an observer (async version).
    fileprivate func handleNotificationAsync(element: AXUIElement, notification: String) {
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

        // Check for TCC
        let isTCC = tccDetector.isTCCDialog(element: element, processName: bundleId)

        // Serialize the dialog
        let dialogText = serialiser.serialize(element: element)
        let buttons = serialiser.extractButtons(element: element)

        // Extract title. Plenty of real dialogs carry no AXTitle at all, and a
        // card headed with an empty string tells you nothing about what you are
        // being asked to approve — so fall back to the first line of the dialog
        // itself, then to the app's name.
        let axTitle = (getAttribute(element, kAXTitleAttribute as CFString) as? String) ?? ""
        let firstLine = dialogText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let title = [axTitle, firstLine, appName]
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Dialog"

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
            bodyText: dialogText,
            options: options,
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
    private static func risk(forButtonLabel label: String) -> RiskLevel {
        let l = label.lowercased()
        let high = ["always allow", "allow", "trust", "delete", "erase", "send",
                    "purchase", "buy", "grant", "enable", "remove", "reset"]
        if high.contains(where: { l.contains($0) }) { return .high }
        let medium = ["ok", "continue", "yes", "install", "open", "save"]
        if medium.contains(where: { l.contains($0) }) { return .medium }
        return .low
    }

    /// Get the window element from a dialog element.
    private func getWindowElement(_ element: AXUIElement) -> AXUIElement? {
        var current = element
        var depth = 0
        while depth < 10 {
            let role = getAttribute(current, kAXRoleAttribute as CFString) as? String
            if role == "AXWindow" {
                return current
            }

            if let parentValue = getAttribute(current, kAXParentAttribute as CFString) {
                current = parentValue as! AXUIElement
                depth += 1
            } else {
                break
            }
        }
        return nil
    }

    /// Safely get an attribute from an AXUIElement.
    private func getAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }
}
