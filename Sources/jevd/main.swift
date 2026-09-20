import Foundation
import AppKit
import CoreImage
import JevCore
import JevAX
import JevCapture
import JevServer
import JevCua
import JevDecide
import JevWeb

#if canImport(Speech)
@preconcurrency import Speech
#endif

// MARK: - Keychain Storage

/// Thread-safe keychain wrapper for storing secrets.
final class KeychainManager {
    static let shared = KeychainManager()
    private let serviceName = "com.jev.agent"

    func store(key: String, value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: value.data(using: .utf8)!
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.storeFailed("Status: \(status)")
        }
    }

    func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// The bearer token the phone presents on every request.
    ///
    /// Deliberately a file, not the Keychain. While the app is ad-hoc signed the
    /// Keychain is only intermittently readable — it works right after a grant
    /// and stops working after the next rebuild — so reading it made the token
    /// silently alternate between two values and invalidated every pairing link
    /// already on the phone. One file, one token, same answer every launch.
    ///
    /// The tradeoff is real: the token sits in a 0600 file readable by your user
    /// account. Move it to the Keychain once Jev.app has a stable signing
    /// identity, at which point the Keychain stops being a coin flip.
    static func loadOrCreatePairingToken() -> String {
        if let existing = try? String(contentsOf: tokenFileURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                JevLog.write("[jev] pairing token loaded")
                return trimmed
            }
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        // Checked, because the failure mode is a FIXED token. An ignored
        // errSecFailure leaves the buffer all zeros, which base64s to a
        // run of A's — written to disk and reused for the life of the
        // install, since the loader prefers whatever file already
        // exists. A guessable bearer token is full remote control.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            JevLog.writeNow("[jev] FATAL: the system would not provide random bytes for a pairing token")
            fatalError("Refusing to start with a predictable pairing token")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        try? FileManager.default.createDirectory(
            at: tokenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Born 0600. Writing then chmodding leaves a window, however
        // small, where the pairing token is world-readable.
        FileManager.default.createFile(atPath: tokenFileURL.path,
                                       contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        JevLog.write("[jev] pairing token created")
        return token
    }

    static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/pairing-token")
    }

    /// Run a Keychain call off-thread and give up after two seconds, so a prompt
    /// that can never be answered cannot wedge the daemon.
    private static func keychainWithTimeout<T>(_ work: @escaping @Sendable () -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 2) == .success ? box.value : nil
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed("Status: \(status)")
        }
    }
}

enum KeychainError: LocalizedError {
    case storeFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let msg):
            return "Keychain store failed: \(msg)"
        case .deleteFailed(let msg):
            return "Keychain delete failed: \(msg)"
        }
    }
}

// MARK: - Permission Checking

struct PermissionChecker {
    /// Check if Accessibility is enabled for this app.
    static func isAccessibilityEnabled() -> Bool {
        // Check without prompting the user.
        let options: [String: NSNumber] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Check if Screen Recording is enabled for this app.
    static func isScreenRecordingEnabled() -> Bool {
        // Ask the system. This previously returned a hardcoded true, so the menu
        // bar showed "Screen Recording: ✓" whether or not it was granted —
        // exactly the sort of reassuring lie that wastes an afternoon.
        // Preflight does not prompt; it only reports.
        CGPreflightScreenCaptureAccess()
    }

    /// Open System Settings to grant Accessibility permission.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to grant Screen Recording permission.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Command Executor

final class CommandExecutor {
    private let policy: Policy
    private let store: ApprovalStore

    init(policy: Policy, store: ApprovalStore) {
        self.policy = policy
        self.store = store
    }

    /// Allowed either by the static policy or because the user previously chose
    /// "Always allow" for this app on their phone.
    func isAllowed(_ bundleId: String) -> Bool {
        policy.allowedBundleIds.contains(bundleId) || AppPolicyStore.shared.effectiveMode(for: bundleId) == .always
    }

    /// `humanApproved` means the person answered a prompt for this exact
    /// command. Their yes IS the authorisation — re-checking the allowlist
    /// afterwards made "Allow once" impossible, since allowing once by
    /// definition adds nothing to the list.
    /// Set by the runtime: opens the text sheet on the paired phone.
    /// Typing is the one input path that must never touch the microphone.
    /// Returns false when no phone is listening, so the command can say so
    /// rather than claim it asked someone.
    nonisolated(unsafe) static var onInputRequested: ((String, Bool) -> Bool)?
    /// Set by the runtime: shows a scanned form on the paired phone.
    nonisolated(unsafe) static var onFormFound: (([FormScanner.Field]) -> Bool)?
    /// Ask the phone to draw numbers over its picture of the screen.
    nonisolated(unsafe) static var onNumbersRequested: ((Bool) -> Bool)?
    /// Set by the runtime: tell the phone what a web task is doing, step by
    /// step. A web task can run for a minute with nothing on screen changing
    /// on the Mac, so without this it looks like nothing is happening.
    nonisolated(unsafe) static var onWebProgress: ((Int, String, String, Bool, Bool) -> Void)?
    /// Set by the runtime: put a card on the phone saying how a web task
    /// ended, with a picture of where it stopped.
    nonisolated(unsafe) static var onWebReport: ((String, String, String?) -> Bool)?
    /// Set by the runtime: stop mid-task and ask before clicking something
    /// consequential. Returns what the person said, or that nobody did.
    nonisolated(unsafe) static var onWebConsent:
        (@Sendable (String, String?) async -> WebAgent.Consent)?

    /// Looking and pointing now go through Cua Driver, which holds its own
    /// Accessibility grant and refuses rather than guesses. See JevCua.
    static let cua = CuaBackend()

    /// - Parameter answeredCard: a PERSON tapped an option on a card for
    ///   this exact request. Deliberately separate from `humanApproved`,
    ///   which also covers "the model decided this was routine" — that is a
    ///   fine reason to skip the app allowlist and a terrible one to skip
    ///   the list of buttons jev must never press on its own. Not
    ///   propagated into a sequence's steps, so a sequence can never carry
    ///   a person's tap into a button press they did not see.
    func execute(_ command: Command,
                 humanApproved: Bool = false,
                 answeredCard: Bool = false) async -> ExecutionResult {
        switch command {
        case .launchApp(let bundleId):
            return executeAppLaunch(bundleId: bundleId, humanApproved: humanApproved)

        case .quitApp(let bundleId):
            return executeAppQuit(bundleId: bundleId, humanApproved: humanApproved)

        case .toggleApp(let bundleId):
            return executeAppToggle(bundleId: bundleId, humanApproved: humanApproved)

        case .showApp(let bundleId):
            guard humanApproved || isAllowed(bundleId) else {
                return .failed(reason: "\(bundleId) is not in the allowlist")
            }
            return showApp(bundleId)

        case .hideApp(let bundleId):
            guard humanApproved || isAllowed(bundleId) else {
                return .failed(reason: "\(bundleId) is not in the allowlist")
            }
            return hideApp(bundleId)

        case .clickControl(let label, let nth, let outOf, let inWindow):
            return await Self.cua.click(labelled: label, nth: nth, outOf: outOf,
                                        inWindow: inWindow)

        case .typeText(let text):
            return await Self.cua.type(text)

        case .clickPoint(let x, let y):
            return await Self.cua.click(normalisedX: x, y: y)

        case .scroll(let direction, let amount):
            return await Self.cua.scroll(direction: direction, amount: amount)

        case .switchWorkspace(let id):
            return AeroSpace.switchTo(id)

        case .pressKeys(let spec):
            return Keystrokes.press(spec)

        case .rightClickControl(let label, let nth, let outOf, let inWindow):
            return await Self.cua.click(labelled: label, button: "right",
                                        nth: nth, outOf: outOf, inWindow: inWindow)

        case .fillField(let label, let text):
            return await Self.cua.fill(field: label, with: text)

        case .systemAction(let name, let value):
            switch name {
            case "volumeUp":    return SystemControl.nudgeVolume(by: value == 0 ? 10 : value)
            case "volumeDown":  return SystemControl.nudgeVolume(by: -(value == 0 ? 10 : value))
            case "volumeSet":   return SystemControl.setVolume(value)
            case "mute":        return SystemControl.setMuted(true)
            case "unmute":      return SystemControl.setMuted(false)
            case "brighter":    return SystemControl.nudgeBrightness(up: true)
            case "dimmer":      return SystemControl.nudgeBrightness(up: false)
            case "darkMode":    return SystemControl.toggleDarkMode()
            case "emptyTrash":  return SystemControl.emptyTrash()
            default:            return .failed(reason: "Unknown system action “\(name)”")
            }

        case .pointerAction(let kind):
            // "this" and "here" mean wherever the pointer is. The phone shows
            // it and lets you drag it, so pointing is a gesture and the words
            // stay short.
            return Pointer.perform(kind, at: Pointer.location())

        case .showNumbers(let on):
            // Nothing happens on the Mac. The phone draws the numbers over
            // its own screenshot, so the Mac looks exactly as it did.
            guard let show = Self.onNumbersRequested, show(on) else {
                return .failed(reason: "No phone is connected to show them on")
            }
            return .ok(reason: on ? "Numbers on screen" : "Numbers off")

        case .showForm:
            let fields: [FormScanner.Field]
            do {
                // Give the unlabelled ones a name here, not later.
                //
                // `FormScanner.nameUnlabelled` looks for labels starting
                // with "Field " and nothing was ever producing one, so the
                // renamer never fired and the phone was shown a form with
                // blank captions that could not be filled back. The number
                // is the box's position among the fields, which is also how
                // `CuaBackend.fill` finds it again.
                let (found, totalFields, formWindow) = try await Self.cua.formFields()
                // Names the form itself uses, so a placeholder never
                // collides with one. A form whose first box is genuinely
                // called "Field 3" and whose third box is unlabelled would
                // otherwise show two boxes with the same name, and filling
                // the unlabelled one would silently write into box 1 —
                // `fill` matches by name before position, as it should.
                let taken = Set(found.map { $0.label.trimmingCharacters(in: .whitespaces).lowercased() })
                fields = found.enumerated().map { index, field in
                    let named = field.label.trimmingCharacters(in: .whitespaces)
                    guard named.isEmpty else {
                        // A page can set aria-label="jev:box:1/3" on its
                        // own input. Used as an address that would resolve
                        // to box 1 instead, so a hostile page could put an
                        // input it reads at position 1 and collect
                        // whatever you typed into the box it labelled.
                        // A name the form chose is a name, never an address.
                        return FormScanner.Field(
                            label: named, secret: field.secret, kind: field.kind,
                            realLabel: CuaBackend.placeholderOrdinal(named) == nil
                                ? named
                                : CuaBackend.positionalAddress(index + 1, of: totalFields, inWindow: formWindow))
                    }
                    // Caption and address are different jobs.
                    //
                    // The caption is for you to read, so it avoids names the
                    // form already uses — two boxes called "Field 2" on one
                    // card is confusing. The ADDRESS is what comes back to
                    // the Mac, and it is positional and unmistakable, so no
                    // amount of caption collision can send your value into
                    // the wrong box.
                    let caption = [CuaBackend.placeholderName(index + 1),
                                   CuaBackend.fallbackName(index + 1)]
                        .first { !taken.contains($0.lowercased()) }
                        ?? CuaBackend.fallbackName(index + 1)
                    return FormScanner.Field(label: caption, secret: field.secret, kind: field.kind,
                                             realLabel: CuaBackend.positionalAddress(index + 1,
                                                                                     of: totalFields, inWindow: formWindow))
                }
            } catch {
                // Say which of the two it is. "Nothing fillable here" is a
                // lie when the truth is that the screen could not be read.
                return .failed(reason: "\(error)")
            }
            guard !fields.isEmpty else {
                return .failed(reason: "Nothing fillable in the frontmost window")
            }
            guard let show = Self.onFormFound else {
                return .failed(reason: "No phone is connected to show it on")
            }
            _ = show
            // Only pays for a model call when the form left fields unnamed.
            let named = await FormScanner.nameUnlabelled(
                fields, nearby: await Self.cua.visibleLabels(limit: 40),
                apiKey: JevAPI.loadAPIKey())
            // Labels only. A field's contents never reach the log, which is
            // the whole reason forms are filled from the phone.
            JevLog.write("[jev] form: " + named.map {
                "\($0.label)\($0.secret ? " (secret)" : "")"
            }.joined(separator: ", "))
            guard show(named) else {
                return .failed(reason: "Found \(named.count) fields, but no phone is connected to show them on")
            }
            return .ok(reason: "Sent \(named.count) field\(named.count == 1 ? "" : "s") to your phone")

        case .requestInput(let field, let secret):
            guard let ask = Self.onInputRequested else {
                return .failed(reason: "No phone is connected to type on")
            }
            // Returning ok here without a phone listening would be this
            // codebase's oldest bug: a command that reports success and does
            // nothing. You would be waiting for a box that never appeared.
            guard ask(field, secret) else {
                return .failed(reason: "No phone is connected to type on")
            }
            return .ok(reason: secret
                ? "Asked your phone for the \(field) — it will not be spoken or logged"
                : "Asked your phone for the \(field)")

        case .webTask(let goal, let startURL):
            return await executeWebTask(goal: goal, startURL: startURL)

        case .openURL(let url):
            guard let target = URL(string: url) else {
                return .failed(reason: "“\(url)” is not a usable address")
            }
            // NSWorkspace hands it to the default browser, which opens a new
            // tab itself. No focus race, no keystrokes, no address bar to
            // clear — all the things that made the typed version fail.
            return NSWorkspace.shared.open(target)
                ? .ok(reason: "Opened \(url)")
                : .failed(reason: "The browser refused \(url)")

        case .sequence(let label, let steps):
            // Whether every step actually landed, not just whether each
            // was delivered. The sequence used to return a bare `.ok`,
            // which would have reported a swallowed press inside it as
            // done. No sequence contains a `.pressButton` today; the
            // laundering would be silent when one does.
            var everythingLanded = true
            // Steps need a beat between them: focusing a field and typing into
            // it in the same instant races, and the text lands nowhere.
            for sub in steps {
                let result = await execute(sub, humanApproved: humanApproved)
                if result.status == .failed {
                    return .failed(reason: "\(label) stopped at “\(result.reason)”")
                }
                if !result.landed { everythingLanded = false }
                // A new tab or a freshly focused field needs longer to settle
                // than a plain keystroke does.
                let settle: Duration = {
                    if case .pressKeys(let spec) = sub,
                       spec.contains("cmd+t") || spec.contains("cmd+l") { return .milliseconds(320) }
                    return .milliseconds(140)
                }()
                try? await Task.sleep(for: settle)
            }
            return .ok(reason: label, landed: everythingLanded)

        case .pressButton(let requestId, let optionId):
            return await executeButtonPress(requestId: requestId, optionId: optionId,
                                            answeredCard: answeredCard)

        case .runCommand(let prefix, let fullCommand):
            if prefix == "__jev_reset" {
                AppPolicyStore.shared.reset()
                return .ok(reason: "Cleared every saved allow/never/auto choice")
            }
            return executeAllowlistedCommand(prefix: prefix, fullCommand: fullCommand)

        case .answerAgentPrompt(let requestId, let optionId):
            return await executeAnswerAgentPrompt(requestId: requestId, optionId: optionId)
        }
    }

    /// Quake-style show/hide, decided by what is actually on screen.
    private func executeAppToggle(bundleId: String, humanApproved: Bool = false) -> ExecutionResult {
        guard humanApproved || isAllowed(bundleId) else {
            return .failed(reason: "\(bundleId) is not in the allowlist")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return executeAppLaunch(bundleId: bundleId, humanApproved: true)
        }
        return JevIntent.hasVisibleWindow(pid: app.processIdentifier)
            ? hideApp(bundleId)
            : showApp(bundleId)
    }

    /// Put an app's window on screen.
    ///
    /// Activation alone is not enough for a dropdown panel: the app draws that
    /// itself and only does so on a reopen event, which is what clicking a Dock
    /// icon sends. So activate, and if nothing appears, reopen the bundle.
    private func showApp(_ bundleId: String) -> ExecutionResult {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return executeAppLaunch(bundleId: bundleId, humanApproved: true)
        }
        let name = app.localizedName ?? bundleId

        app.unhide()
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.25)

        // Name the window we meant. Without this, activation surfaces whichever
        // window the app prefers — for a quake terminal that is the ordinary
        // one, not the dropdown you asked for.
        let raisedPanel = JevIntent.raisePanel(pid: app.processIdentifier)
        if raisedPanel { Thread.sleep(forTimeInterval: 0.2) }

        if JevIntent.hasVisibleWindow(pid: app.processIdentifier) {
            return .ok(reason: raisedPanel ? "Showed \(name)’s panel" : "Showed \(name)")
        }

        // No reopen fallback here on purpose. Reopening the bundle sends the
        // same event as clicking a Dock icon, and an app with a dropdown panel
        // answers it by creating a NEW ordinary window — which litters the
        // desktop instead of revealing the panel you meant. Failing honestly is
        // better than doing something else and calling it success.
        return .failed(reason: "\(name) is running but will not show its window from here — it needs its own hotkey or CLI")
    }

    /// Take an app's window off screen.
    ///
    /// hide() does not touch windows at an elevated level, so a floating panel
    /// survives it. Fall back to asking the window to close, then to Escape.
    private func hideApp(_ bundleId: String) -> ExecutionResult {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return .ok(reason: "Not running")
        }
        let name = app.localizedName ?? bundleId
        guard JevIntent.hasVisibleWindow(pid: app.processIdentifier) else {
            return .ok(reason: "\(name) is already hidden")
        }

        app.hide()
        Thread.sleep(forTimeInterval: 0.2)
        if !JevIntent.hasVisibleWindow(pid: app.processIdentifier) {
            return .ok(reason: "Hid \(name)")
        }

        if JevIntent.dismissFrontWindow(pid: app.processIdentifier) {
            Thread.sleep(forTimeInterval: 0.2)
            if !JevIntent.hasVisibleWindow(pid: app.processIdentifier) {
                return .ok(reason: "Dismissed \(name)")
            }
        }

        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.1)
        _ = Keystrokes.press("escape")
        Thread.sleep(forTimeInterval: 0.2)
        return JevIntent.hasVisibleWindow(pid: app.processIdentifier)
            ? .failed(reason: "\(name) keeps its window on top and ignored hide, close and escape")
            : .ok(reason: "Hid \(name)")
    }

    private func executeAppQuit(bundleId: String, humanApproved: Bool = false) -> ExecutionResult {
        guard humanApproved || isAllowed(bundleId) else {
            return .failed(reason: "\(bundleId) is not in the allowlist")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else {
            return .ok(reason: "Already not running")
        }
        let name = running.first?.localizedName ?? bundleId
        for app in running { app.terminate() }

        // terminate() only *asks*. An app with unsaved work puts up a save
        // sheet and keeps running, so reporting success here told you the app
        // was gone while it sat there waiting for an answer — an answer jev
        // will now surface on your phone as an approval.
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
                return .ok(reason: "Quit \(name)")
            }
        }
        return .failed(reason: "\(name) did not quit — it is probably asking what to do with unsaved work")
    }

    /// Carry out a goal in the browser the person is already signed into.
    ///
    /// This reads the page, decides one step, carries it out, and reads again,
    /// until the goal is met, refused, or the budget runs out. It **does**
    /// click and type — through the DevTools target rather than the operating
    /// system, so it never takes the pointer or the keyboard, but the effect
    /// on a signed-in site is real. The tab is left open afterwards whatever
    /// happened, because it is the evidence.
    private func executeWebTask(goal: String, startURL: String?) async -> ExecutionResult {
        // The start is resolved here, from what was said and what is already
        // open — never by a model. BrowserContext reads the frontmost tab
        // through Apple Events, which jev already has consent for.
        let start: WebStart.Start = startURL.map { .url($0) }
            ?? WebStart.resolve(goal: goal, currentHost: BrowserContext.currentHost())

        // One connection, held across tasks. Chrome prompts for each new
        // debugging connection, so opening one per task would ask every time.
        let session: WebSession
        do {
            session = try await WebBrowser.shared.acquire()
        } catch WebBrowser.Failure.unavailable(let why) {
            // Names the next action rather than the fault. The states need
            // different sentences — telling someone to restart Chrome when a
            // consent prompt is waiting costs them every open tab.
            return .failed(reason: why)
        } catch WebBrowser.Failure.session(.cdp(.sessionRefused)) {
            // The profile toggle can read "on" while Chrome still refuses the
            // session: the per-browser opt-in and the per-connection grant are
            // different things. Says the one thing that actually helps.
            return .failed(reason: "Chrome would not open a debugging session. "
                                 + "Look for an \"Allow remote debugging\" prompt in Chrome, "
                                 + "or restart Chrome and try again.")
        } catch {
            return .failed(reason: "Could not reach Chrome")
        }

        do {
            switch start {
            case .url(let url):
                try await session.navigate(to: url)
            case .currentTab:
                // A tab of our own starts blank, so "the page you are on" means
                // going to it rather than borrowing the tab itself.
                guard let host = BrowserContext.currentHost() else {
                    return .failed(reason: WebStart.cannotStart)
                }
                try await session.navigate(to: "https://\(host)/")
            case .unknown:
                return .failed(reason: WebStart.cannotStart)
            }

            guard let apiKey = JevAPI.loadAPIKey() else {
                return .failed(reason: "No TypeSafe API key, so there is nothing to decide with")
            }

            let agent = WebAgent(
                session: session,
                apiKey: apiKey,
                // Reuse the rating jev already applies to buttons — tuned over
                // a hundred and fifty real labels, negations and deferrals
                // included — and add only what a shop words differently.
                needsConsent: { label in
                    DialogWatcher.risk(forButtonLabel: label) == .high
                        || WebSafety.looksConsequential(label)
                },
                askConsent: { label, picture in
                    guard let ask = Self.onWebConsent else { return .no }
                    return await ask(label, picture)
                }
            ) { progress in
                // The label comes from the page, so it can contain newlines.
                // Written raw it forges entries in the daemon's own log.
                let label = progress.target
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                JevLog.write("[jev] web step \(progress.step)"
                           + "\(progress.isRetry ? " (retry)" : ""): "
                           + "\(progress.operation) \(label.prefix(40))")
                // A web task changes nothing on the Mac's screen, so without
                // this the phone shows a spinner and no reason to trust it.
                Self.onWebProgress?(progress.step, progress.operation,
                                    String(label.prefix(60)), progress.isRetry, false)
            }
            let outcome = await agent.run(goal: goal)
            // The tab is left open whatever happened: it is the evidence, and
            // the person should be able to look at what jev did. Only the
            // socket is dropped — and only after any picture has been taken,
            // since taking one needs it.

            // Whatever happened, take the progress banner down.
            Self.onWebProgress?(0, "", "", false, true)

            switch outcome {
            case .done(let steps, let url, let title):
                return .ok(reason: "Done in \(steps) step\(steps == 1 ? "" : "s") — "
                                 + "\(title.isEmpty ? url : title)")

            case .blocked(let why, let steps, _, let title):
                // A refusal is the one outcome that has to be seen rather than
                // read out: the person needs to know what jev would not do and
                // where it stopped, so the picture goes with it. Informational
                // — the task is already over, and nothing here resumes it.
                let picture = await session.screenshot()
                _ = Self.onWebReport?("jev stopped in your browser",
                                      "\(why).\n\nOn: \(title)\nAfter \(steps) step"
                                      + "\(steps == 1 ? "" : "s"). The tab is still open.",
                                      picture)
                return .failed(reason: "Stopped after \(steps) step\(steps == 1 ? "" : "s") "
                                     + "on \(title): \(why)")

            case .stuck(let steps, _, let title):
                let picture = await session.screenshot()
                _ = Self.onWebReport?("jev could not finish that",
                                      "Nothing on the page moved it forward.\n\nOn: \(title)\n"
                                      + "After \(steps) step\(steps == 1 ? "" : "s"). "
                                      + "The tab is still open.",
                                      picture)
                return .failed(reason: "Could not find a way forward on \(title)"
                                     + (steps == 0 ? "" : " after \(steps) steps"))

            case .refusedByPerson(let what, let steps, _, let title):
                return .failed(reason: "Stopped — you said no to “\(what.prefix(40))” on "
                                     + "\(title) after \(steps) step\(steps == 1 ? "" : "s")")

            case .unanswered(let what, let steps, _, let title):
                return .failed(reason: "Stopped — nobody answered about “\(what.prefix(40))” on "
                                     + "\(title) after \(steps) step\(steps == 1 ? "" : "s")")

            case .exhausted(let steps, _, let title):
                let picture = await session.screenshot()
                _ = Self.onWebReport?("jev ran out of steps",
                                      "Stopped after \(steps) steps without finishing.\n\n"
                                      + "On: \(title). The tab is still open.",
                                      picture)
                return .failed(reason: "Gave up after \(steps) steps on \(title)")

            case .failed(let why, let steps):
                return .failed(reason: steps == 0 ? "Could not start: \(why)"
                                                  : "Stopped after \(steps) steps: \(why)")
            }
        } catch {
            // Never echoes the page or the endpoint path: one is whatever they
            // were looking at, the other is a credential.
            return .failed(reason: "Could not read the page (\(error))")
        }
    }

    private func executeAppLaunch(bundleId: String, humanApproved: Bool = false) -> ExecutionResult {
        guard humanApproved || isAllowed(bundleId) else {
            return .failed(reason: "Bundle ID not in allowlist")
        }

        let config = NSWorkspace.OpenConfiguration()
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        if let app = app, !app.isTerminated {
            let name = app.localizedName ?? bundleId
            app.unhide()
            app.activate(options: .activateAllWindows)
            Thread.sleep(forTimeInterval: 0.25)

            if JevIntent.hasVisibleWindow(pid: app.processIdentifier) {
                return .ok(reason: "Brought \(name) forward")
            }

            // Running, but nothing on screen: a tiling manager has its windows
            // parked on another workspace. Try to fetch one here.
            if AeroSpace.isInstalled, AeroSpace.summonFocusedWindowHere() {
                Thread.sleep(forTimeInterval: 0.3)
                if JevIntent.hasVisibleWindow(pid: app.processIdentifier) {
                    return .ok(reason: "Brought \(name) to this workspace")
                }
            }
            return .failed(reason: "\(name) is running but its windows are on another workspace")
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return .failed(reason: "Could not find app with bundle ID \(bundleId)")
        }
        _ = url

        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        NSWorkspace.shared.open([url], withApplicationAt: url, configuration: config)

        // open() returns before the app exists. Reporting success immediately
        // meant "launch X" was reported done whether or not X ever started —
        // including when it crashed on launch or the bundle was damaged.
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if let launched = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).first, !launched.isTerminated {
                return .ok(reason: "Launched \(name)")
            }
        }
        return .failed(reason: "\(name) was asked to launch but has not started")
    }

    private func executeButtonPress(requestId: String, optionId: String,
                                    answeredCard: Bool = false) async -> ExecutionResult {
        guard let request = await store.get(id: requestId) else {
            return .failed(reason: "Request not found")
        }

        guard let option = request.options.first(where: { $0.id == optionId }) else {
            return .failed(reason: "Option not found in request")
        }

        // Only when nobody asked for it. The reason string always said
        // "cannot be AUTO-pressed", and the guard was running on the human's
        // own tap as well — so a card whose button happened to contain
        // "delete", "send", "trust" or "grant" was unanswerable from the
        // phone, and said so in a sentence nobody ever saw.
        guard answeredCard
                || !policy.dangerousButtonLabels.contains(where: { option.label.lowercased().contains($0.lowercased()) }) else {
            return .failed(reason: "“\(option.label)” is one jev will never press on its own — answer it at the Mac")
        }

        // A TCC consent sheet ignores synthetic input by design. Returning success
        // here would tell the phone the job was done while nothing happened.
        guard !request.handoffOnly else {
            return .failed(reason: "System permission dialog — only a real key press or click answers this. "
                + "No remote tool can, including Screen Sharing. Grant it at the Mac once and it stops asking.")
        }

        guard let element = DialogRegistry.shared.element(for: requestId) else {
            return .failed(reason: "That dialog is no longer on screen — dismissed or expired.")
        }

        let presser = ButtonPresser(policy: policy)
        let result = await presser.pressButton(in: element, withLabel: option.label,
                                               humanApproved: answeredCard)

        switch result {
        case .success(let message, let dialogGone):
            // Only on success. Discarding unconditionally threw away the
            // handle to a dialog that is still on screen the moment a
            // press did not land — Chrome busy for a second is enough —
            // and the card raised to tell you about it was then withdrawn
            // by the sweep within two seconds, because a discarded id
            // reports as dead. The dialog became permanently unreachable,
            // and the watcher only fires again on a NEW window.
            //
            // …and only when the dialog actually went away. `.success`
            // from the accessibility API means the press was delivered,
            // not that anything happened: a macOS consent sheet accepts
            // it and ignores it. Discarding there threw away the handle
            // to a sheet that is still on screen.
            if dialogGone { DialogRegistry.shared.discard(id: requestId) }
            return .ok(reason: message, landed: dialogGone)
        case .notFound(let message):
            return .failed(reason: message)
        case .forbidden(let message):
            return .failed(reason: message)
        case .accessibilityError(let message):
            return .failed(reason: message)
        }
    }

    private func executeAllowlistedCommand(prefix: String, fullCommand: String) -> ExecutionResult {
        guard policy.allowedCommandPrefixes.contains(prefix) else {
            return .failed(reason: "Command prefix not in allowlist")
        }

        guard fullCommand.hasPrefix(prefix) else {
            return .failed(reason: "Full command does not match declared prefix")
        }

        // A prefix check alone is not a sandbox. Via `/bin/sh -c` an allowlisted
        // "git " prefix would happily accept "git status; rm -rf ~". Refuse shell
        // metacharacters outright and execute argv directly with no shell.
        let forbidden: Set<Character> = [";", "&", "|", "`", "$", ">", "<", "\n", "\r", "(", ")", "{", "}", "\\", "\""]
        guard !fullCommand.contains(where: { forbidden.contains($0) }) else {
            return .failed(reason: "Command contains shell metacharacters and was refused")
        }

        let argv = fullCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let executable = argv.first else {
            return .failed(reason: "Empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(argv.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Read BEFORE waiting. A command writing more than the pipe
            // buffer — about 64 KB — blocks on the write while we block
            // on the exit, and the executor wedges for good. Latent only
            // because the allowlist ships empty; live the day anyone
            // adds a prefix.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                // Not the whole of stdout. `reason` is journalled, written
                // to disk and served by /api/journal, and a command's
                // output is arbitrary — latent only because the allowlist
                // ships empty, and live the day anyone adds a prefix.
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let head = trimmed.prefix(200)
                return .ok(reason: trimmed.isEmpty
                    ? "Command ran, no output"
                    : "Command ran: \(head)\(trimmed.count > 200 ? "…" : "")")
            } else {
                return .failed(reason: "Command failed with status \(process.terminationStatus)")
            }
        } catch {
            return .failed(reason: "Failed to execute command: \(error.localizedDescription)")
        }
    }

    private func executeAnswerAgentPrompt(requestId: String, optionId: String) async -> ExecutionResult {
        guard let request = await store.resolve(id: requestId) else {
            return .failed(reason: "Request not found or already resolved")
        }

        guard request.options.contains(where: { $0.id == optionId }) else {
            return .failed(reason: "Option not found in request")
        }

        // Signal to Claude Code that the approval was resolved
        return .ok(reason: "Agent prompt answered with option \(optionId)")
    }
}

// MARK: - Transcriber Protocol

/// What the recogniser heard, including the readings it ranked lower.
///
/// Speech recognition returns several candidate transcriptions and the old
/// code kept only the top one. That single string is often the wrong reading
/// of a short command — "quit Notes" comes back as "open Notes" — and the
/// correct one is frequently sitting in the list that was thrown away.
struct Heard: Sendable {
    let best: String
    /// Lower-ranked readings, best first, excluding `best`.
    let alternatives: [String]
    /// Mean per-segment confidence of `best`; 0 when the recogniser does not
    /// report one, which on-device recognition often does not.
    let confidence: Double
}

protocol Transcriber: Sendable {
    func transcribe(audioURL: URL) async -> Result<Heard, TranscriptionError>
}

enum TranscriptionError: LocalizedError {
    case noSpeechDetected
    case recognitionFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noSpeechDetected:
            return "No speech detected in audio"
        case .recognitionFailed(let msg):
            return "Recognition failed: \(msg)"
        case .unsupportedFormat:
            return "Audio format not supported"
        }
    }
}

// MARK: - SpeechRecognizer Implementation

final class SpeechRecognizer: NSObject, Transcriber, SFSpeechRecognizerDelegate {
    private let recognizer: SFSpeechRecognizer?

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    func transcribe(audioURL: URL) async -> Result<Heard, TranscriptionError> {
        guard let recognizer = recognizer else {
            return .failure(.recognitionFailed("Speech recognizer unavailable"))
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        // These are short imperative phrases, not dictation. The search hint
        // stops the recogniser reaching for fluent sentences, and punctuation
        // only ever added characters the matcher then had to strip off again.
        request.taskHint = .search
        if #available(macOS 13.0, *) { request.addsPunctuation = false }
        // Tell the recogniser what words are plausible here. Short, unusual app
        // names — "Waz", "Ghostty", "AeroSpace" — are otherwise transcribed as
        // ordinary English ("was", "ghost tea"), and no amount of matching
        // downstream can recover a word that was never heard.
        request.contextualStrings = Transcription.recognitionHints()

        return await withCheckedContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(returning: .failure(.recognitionFailed(error.localizedDescription)))
                    return
                }

                guard let result = result else {
                    continuation.resume(returning: .failure(.noSpeechDetected))
                    return
                }

                let best = result.bestTranscription.formattedString
                if best.isEmpty {
                    continuation.resume(returning: .failure(.noSpeechDetected))
                    return
                }

                let scored = result.bestTranscription.segments
                    .map { Double($0.confidence) }.filter { $0 > 0 }
                let confidence = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)

                var alternatives: [String] = []
                for transcription in result.transcriptions {
                    let text = transcription.formattedString
                    guard !text.isEmpty, text != best, !alternatives.contains(text) else { continue }
                    alternatives.append(text)
                }

                continuation.resume(returning: .success(
                    Heard(best: best, alternatives: Array(alternatives.prefix(4)), confidence: confidence)))
            }
        }
    }
}

// MARK: - QR Code Generation

struct QRCodeGenerator {
    static func generateQRCode(from string: String, size: CGSize = CGSize(width: 200, height: 200)) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaleX = size.width / outputImage.extent.width
        let scaleY = size.height / outputImage.extent.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let rep = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        return image
    }
}

// MARK: - Main App Delegate

final class JevAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var store: ApprovalStore?
    private var executor: CommandExecutor?
    private var policy: Policy?
    private var runtime: JevRuntime?
    private var pairingWindow: NSWindow?

    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        startUp()
    }

    /// Called directly from the entry point rather than waiting on
    /// applicationDidFinishLaunching. For a programmatic LSUIElement app that
    /// notification is easy to miss, and missing it means the daemon silently
    /// does nothing at all. Guarded so the delegate callback cannot double-run it.
    func startUp() {
        guard !didStart else { return }
        didStart = true
        JevLog.write("[jev] starting up")
        // Initialize components
        let appStore = ApprovalStore()

        // Enumerate what is actually installed and allow launching/quitting any
        // of it. Shell commands and dangerous dialog buttons stay locked down
        // separately — this widens app control only.
        // The catalog exists so spoken names resolve to bundle ids. It does NOT
        // pre-approve anything: unknown apps raise an approval on your phone,
        // and "Always allow" is what builds the list over time.
        AppCatalog.shared.refresh()
        let appPolicy = Policy.strictDefault()
        JevLog.write("[jev] app catalog: \(AppCatalog.shared.all.count) apps known, \(AppPolicyStore.shared.all.count) with a saved mode")
        let appExecutor = CommandExecutor(policy: appPolicy, store: appStore)

        store = appStore
        policy = appPolicy
        executor = appExecutor

        // Before anything writes: everything jev keeps is owner-only.
        JevLog.protectSupportFiles()

        // Run self-tests
        CuaDriver.log = { JevLog.write($0) }
        var testFailures = SelfTest.run()
        // The push crypto is unverifiable from the outside — a wrong key
        // derivation just means a notification that never arrives — so it
        // round-trips against a local receiver at every launch.
        testFailures.append(contentsOf: runBlocking { await webPushSelfTest() })
        testFailures.append(contentsOf: vapidSubjectSelfTest())
        // The approval store is an actor, so its checks need the same
        // treatment. Three of the last two rounds' findings were in here
        // and none of them had a test.
        testFailures.append(contentsOf: runBlocking { await SelfTest.runStore() })
        testFailures.append(contentsOf: SelfTest.checkHeadings(DialogWatcher.heading))
        testFailures.append(contentsOf: SelfTest.checkWidgetNoise { DialogSerialiser.isWidgetNoise($0, appName: $1) })
        testFailures.append(contentsOf: SelfTest.checkButtonChoice(DialogSerialiser.chooseButton))
        testFailures.append(contentsOf: SelfTest.checkConsentButtons(TCCDetector.looksLikeConsentButtons))
        testFailures.append(contentsOf: SelfTest.checkRisk(DialogWatcher.risk))
        testFailures.append(contentsOf: SelfTest.checkAutoPressable(DialogWatcher.isKnownSafeLabel))
        testFailures.append(contentsOf: SelfTest.checkReasonEcho(JevRuntime.reasonEchoes))
        testFailures.append(contentsOf: SelfTest.checkOrdinal(JevRuntime.ordinal))
        testFailures.append(contentsOf: SelfTest.checkBadgeNumber(JevRuntime.badgeNumber))
        testFailures.append(contentsOf: SelfTest.checkControlGate(
            JevRuntime.controlPhrase, JevRuntime.exactlyOneControl))
        testFailures.append(contentsOf: SelfTest.checkConsentSheet(TCCDetector.isConsentSheet))
        testFailures.append(contentsOf: SelfTest.checkPaths(HTTPPath.canonicalPath))
        // What you say must keep meaning what it meant.
        testFailures.append(contentsOf: VocabularySelfTest.run())
        testFailures.append(contentsOf: CommandCodableSelfTest.run())
        testFailures.append(contentsOf: CuaSelfTest.run())
        testFailures.append(contentsOf: HIDBridgeSelfTest.run())
        // The browser backend never reaches a browser at launch; what it
        // checks is the vendored table builder and the endpoint parser,
        // both of which decide what a model is allowed to see.
        testFailures.append(contentsOf: WebSelfTest.run())
        testFailures.append(contentsOf: runBlocking { await WebSelfTest.runAsync() })
        JevLog.write("[jev] self-tests: \(testFailures.isEmpty ? "pass" : "FAIL \(testFailures)")")
        if !testFailures.isEmpty {
            printOnboardingWarning("Self-tests failed:")
            for failure in testFailures {
                print("  - \(failure)")
            }
            return
        }

        // Check onboarding
        checkOnboarding()

        JevLog.write("[jev] onboarding checked; building menu bar")
        // Set up menu bar
        setupMenuBar()
        JevLog.write("[jev] menu bar ready; starting runtime")

        // Start the actual product: server on the tailnet, dialog watcher, decider.
        let jevRuntime = JevRuntime(
            policy: appPolicy,
            store: appStore,
            executor: appExecutor
        )
        runtime = jevRuntime
        JevLog.write("[jev] runtime constructed; scheduling start")
        Task { await jevRuntime.start() }
    }

    /// Repopulate the existing menu each time it opens. Rebuilding the whole
    /// status item here would add a second icon to the menu bar every time; the
    /// menu object stays, only its contents are refreshed. Without this the
    /// permission lines were fixed at launch, so "Accessibility: ✗" stayed on
    /// screen forever even after the permission was granted.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func setupMenuBar() {
        let statusBar = NSStatusBar.system
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "Jev")
            button.title = "Jev"
        }

        let menu = NSMenu()
        populate(menu)
        menu.delegate = self
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Tailnet URL
        let urlItem = NSMenuItem(title: Tailnet.displayName(), action: nil, keyEquivalent: "")
        urlItem.isEnabled = false
        menu.addItem(urlItem)

        menu.addItem(NSMenuItem.separator())

        // Pairing
        let pairingItem = NSMenuItem(title: "Pairing…", action: #selector(showPairingDialog), keyEquivalent: "")
        pairingItem.target = self
        menu.addItem(pairingItem)

        menu.addItem(NSMenuItem.separator())

        // Permissions
        let accessibilityStatus = PermissionChecker.isAccessibilityEnabled() ? "✓" : "✗"
        let accessibilityItem = NSMenuItem(
            title: "Accessibility: \(accessibilityStatus)",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        menu.addItem(accessibilityItem)

        let screenStatus = PermissionChecker.isScreenRecordingEnabled() ? "✓" : "✗"
        let screenItem = NSMenuItem(
            title: "Screen Recording: \(screenStatus)",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        )
        menu.addItem(screenItem)

        menu.addItem(NSMenuItem.separator())

        // Auto-approve toggle
        let autoApproveItem = NSMenuItem(title: "Auto-approve under policy", action: #selector(toggleAutoApprove), keyEquivalent: "")
        menu.addItem(autoApproveItem)

        // Pending approvals count
        let countItem = NSMenuItem(title: "Pending: 0", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    @objc private func showPairingDialog() {
        // Read the live values once. Every one of these shells out, so calling
        // them repeatedly while building the view is wasteful.
        JevLog.write("[jev] pairing dialog opening")
        let token = KeychainManager.loadOrCreatePairingToken()
        let device = Tailnet.displayName()
        let serveActive = Tailnet.serveIsActive()
        let pairingURL = Tailnet.pairingURL(token: token, localPort: 8787)
        JevLog.write("[jev] pairing dialog: device=\(device) serve=\(serveActive) "
            + "url=\(Tailnet.loggableURL(token: token, localPort: 8787))")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Pair this device")
        title.font = NSFont.systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        let deviceLabel = NSTextField(labelWithString: device)
        deviceLabel.font = NSFont.boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(deviceLabel)

        if !serveActive {
            let warn = NSTextField(wrappingLabelWithString:
                "No HTTPS yet. Run:  tailscale serve --bg 8787\nVoice and notifications need a secure origin.")
            warn.textColor = .systemOrange
            warn.alignment = .center
            warn.preferredMaxLayoutWidth = 360
            stack.addArrangedSubview(warn)
        }

        let urlField = NSTextField(wrappingLabelWithString: pairingURL)
        urlField.isSelectable = true
        urlField.alignment = .center
        urlField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        urlField.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(urlField)

        let qrImage = QRCodeGenerator.generateQRCode(from: pairingURL)
        JevLog.write("[jev] pairing dialog: qr generated=\(qrImage != nil) size=\(qrImage?.size ?? .zero)")
        if let qr = qrImage {
            let imageView = NSImageView(image: qr)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.heightAnchor.constraint(equalToConstant: 240),
                imageView.widthAnchor.constraint(equalToConstant: 240),
            ])
            stack.addArrangedSubview(imageView)
        } else {
            stack.addArrangedSubview(NSTextField(labelWithString: "(QR code could not be generated)"))
        }

        let copyButton = NSButton(title: "Copy link", target: self, action: #selector(copyPairingURL))
        copyButton.identifier = NSUserInterfaceItemIdentifier(pairingURL)
        stack.addArrangedSubview(copyButton)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Pair Jev Device"
        window.isReleasedWhenClosed = false

        // A bare NSStackView with autoresizing off cannot be the contentView:
        // nothing constrains its size, so it lays out at zero and the window
        // comes up empty. Put it in a container and pin it.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        window.contentView = container

        window.center()
        // Held in a property: a window kept only in a local can be deallocated
        // the moment this function returns.
        pairingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        JevLog.write("[jev] pairing dialog shown, contentView size=\(window.contentView?.frame.size ?? .zero) subviews=\(window.contentView?.subviews.count ?? 0)")
    }

    @objc private func copyPairingURL(_ sender: NSButton) {
        guard let url = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        sender.title = "Copied"
    }

    @objc private func openAccessibilitySettings() {
        PermissionChecker.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        PermissionChecker.openScreenRecordingSettings()
    }

    @objc private func toggleAutoApprove() {
        // Toggle auto-approve setting
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func checkOnboarding() {
        let defaults = UserDefaults.standard
        let hasCompletedOnboarding = defaults.bool(forKey: "JevOnboardingCompleted")

        if !hasCompletedOnboarding {
            printOnboarding()
            defaults.set(true, forKey: "JevOnboardingCompleted")
        }

        if !PermissionChecker.isAccessibilityEnabled() {
            printOnboardingWarning("Accessibility permission not granted. Please enable in System Settings.")
            PermissionChecker.openAccessibilitySettings()
        }

        if !PermissionChecker.isScreenRecordingEnabled() {
            printOnboardingWarning("Screen Recording permission not granted. Please enable in System Settings.")
            PermissionChecker.openScreenRecordingSettings()
        }
    }

    private func printOnboarding() {
        let message = """
        ========================================
        Welcome to Jev
        ========================================
        Jev detects dialogs on your Mac and asks for your approval before acting.

        To pair your phone:
        1. Open Jev in your menu bar (top right)
        2. Click "Pairing..." to see the QR code
        3. Scan the QR code with your phone
        4. The PWA will appear; add it to your Home Screen

        Jev needs two permissions:
        - Accessibility (to read and interact with dialogs)
        - Screen Recording (to capture screenshots)

        Both are available in System Settings > Security & Privacy.

        Questions? See the README or visit the docs.
        ========================================
        """
        print(message)
    }

    private func printOnboardingWarning(_ message: String) {
        print("[Jev Warning] \(message)")
    }
}

// MARK: - Application Entry Point

let app = NSApplication.shared
// Accessory: menu bar only, no Dock icon, no menu bar takeover.
app.setActivationPolicy(.accessory)
let delegate = JevAppDelegate()
app.delegate = delegate
// Run the run loop first, then start. Keychain and AppKit both misbehave when
// driven before NSApplication.run().
DispatchQueue.main.async { delegate.startUp() }

// For a menu bar app, set LSUIElement to hide the Dock icon.
// This is already set in Info.plist via build-app.sh.

app.run()
