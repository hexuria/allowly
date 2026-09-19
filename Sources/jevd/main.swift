import Foundation
import AppKit
import CoreImage
import JevCore
import JevAX
import JevCapture
import JevServer
import JevDecide

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
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        try? FileManager.default.createDirectory(
            at: tokenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? token.write(to: tokenFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
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

// MARK: - Audit Logging

struct AuditLogger {
    static let shared = AuditLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.jev.audit", attributes: .concurrent)

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let jevDir = supportDir.appendingPathComponent("jev")
        try? FileManager.default.createDirectory(at: jevDir, withIntermediateDirectories: true)
        fileURL = jevDir.appendingPathComponent("audit.jsonl")
    }

    func log(command: Command, result: ExecutionResult) {
        queue.async(flags: .barrier) {
            let entry: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "command": encodeCommand(command),
                "status": result.status.rawValue,
                "reason": result.reason
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let logEntry = jsonString + "\n"

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                    handle.seekToEndOfFile()
                    handle.write(logEntry.data(using: .utf8) ?? Data())
                    try? handle.close()
                }
            } else {
                try? logEntry.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func encodeCommand(_ command: Command) -> String {
        switch command {
        case .launchApp(let bundleId):
            return "launchApp(\(bundleId))"
        case .pressButton(let requestId, let optionId):
            return "pressButton(\(requestId), \(optionId))"
        case .quitApp(let bundleId):
            return "quitApp(\(bundleId))"
        case .toggleApp(let bundleId):
            return "toggleApp(\(bundleId))"
        case .showApp(let bundleId):
            return "showApp(\(bundleId))"
        case .hideApp(let bundleId):
            return "hideApp(\(bundleId))"
        case .clickControl(let label):
            return "clickControl(\(label))"
        case .typeText(let text):
            return "typeText(\(text.prefix(40)))"
        case .clickPoint(let x, let y):
            return "clickPoint(\(x),\(y))"
        case .scroll(let direction, let amount):
            return "scroll(\(direction),\(amount))"
        case .switchWorkspace(let id):
            return "switchWorkspace(\(id))"
        case .pressKeys(let spec):
            return "pressKeys(\(spec))"
        case .rightClickControl(let label):
            return "rightClickControl(\(label))"
        case .showHints:
            return "showHints"
        case .showHintsForApp(let bundleId):
            return "showHintsForApp(\(bundleId))"
        case .showHintsEverywhere:
            return "showHintsEverywhere"
        case .showHintsScoped(let kind, let region):
            return "showHintsScoped(\(kind),\(region))"
        case .showHintBox(let number):
            return "showHintBox(\(number))"
        case .systemAction(let name, let value):
            return "systemAction(\(name),\(value))"
        case .selectHint(let number):
            return "selectHint(\(number))"
        case .hideHints:
            return "hideHints"
        case .pointerAction(let kind):
            return "pointerAction(\(kind))"
        case .requestInput(let field, let secret):
            return "requestInput(\(field), secret: \(secret))"
        case .showForm:
            return "showForm"
        case .openURL(let url):
            return "openURL(\(url))"
        case .fillField(let label, _):
            // The value is deliberately not recorded: this is how passwords
            // and other secrets get filled.
            return "fillField(\(label), <redacted>)"
        case .sequence(let label, let steps):
            return "sequence(\(label), \(steps.count) steps)"
        case .runCommand(let prefix, let fullCmd):
            return "runCommand(\(prefix), \(fullCmd))"
        case .answerAgentPrompt(let requestId, let optionId):
            return "answerAgentPrompt(\(requestId), \(optionId))"
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
    /// Work out which kind of thing a spoken noun means.
    ///
    /// Jev is the general answer here: mapping an arbitrary word onto one of a
    /// handful of fixed kinds is a closed choice, which is exactly what it is
    /// good at, and it needs no per-site table to keep up to date.
    static func resolveGuideNoun(_ noun: String) async -> HintScope.Kind? {
        let context = Phrasebook.context()
        if let known = HintScope.Kind.spoken[noun] { return known }
        if let sited = AppProfiles.guideKind(for: noun, in: context) {
            JevLog.write("[jev] guides: “\(noun)” means \(sited.rawValue) on \(context.host ?? "")")
            return sited
        }
        guard let apiKey = JevAPI.loadAPIKey() else { return nil }

        let kinds = HintScope.Kind.allCases.map(\.rawValue)
        let result = await JevAPI.ask(
            state: [
                "asked_for": noun,
                "frontmost_app": context.appName,
                "page": context.host ?? "",
            ],
            questions: [
                "kind": .choice(
                    instructions: "Someone asked a Mac assistant to number “\(noun)” on screen so they can pick one by number. Which kind of on-screen element are they talking about? On a web page, tiles and cards and search results are links.",
                    labels: kinds)
            ],
            apiKey: apiKey)

        guard case .success(let answers) = result,
              let answer = answers.choice("kind"), answer.confidence >= 0.45,
              let kind = HintScope.Kind(rawValue: answer.choice) else { return nil }
        JevLog.write("[jev] guides: Jev reads “\(noun)” as \(kind.rawValue) "
            + "(\(String(format: "%.2f", answer.confidence)))")
        return kind
    }

    /// Set by the runtime: opens the text sheet on the paired phone.
    /// Typing is the one input path that must never touch the microphone.
    /// Returns false when no phone is listening, so the command can say so
    /// rather than claim it asked someone.
    nonisolated(unsafe) static var onInputRequested: ((String, Bool) -> Bool)?
    /// Set by the runtime: shows a scanned form on the paired phone.
    nonisolated(unsafe) static var onFormFound: (([FormScanner.Field]) -> Bool)?

    func execute(_ command: Command, humanApproved: Bool = false) async -> ExecutionResult {
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

        case .clickControl(let label):
            return JevIntent.clickFrontmostControl(labelled: label)

        case .typeText(let text):
            return JevIntent.typeIntoFrontmost(text)

        case .clickPoint(let x, let y):
            return JevIntent.click(x: x, y: y)

        case .scroll(let direction, let amount):
            return JevIntent.scroll(direction: direction, amount: amount)

        case .switchWorkspace(let id):
            return AeroSpace.switchTo(id)

        case .pressKeys(let spec):
            return Keystrokes.press(spec)

        case .rightClickControl(let label):
            return JevIntent.rightClickFrontmostControl(labelled: label)

        case .fillField(let label, let text):
            return JevIntent.fill(field: label, with: text)

        case .showHintsEverywhere:
            let all = Hints.shared.refresh(scope: .everythingOnScreen)
            return all.isEmpty
                ? .failed(reason: "Nothing on screen exposes anything clickable")
                : .ok(reason: "Showing \(all.count) numbers across every visible window")

        case .showHintsForApp(let bundleId):
            let named = Hints.shared.refresh(scope: .app(bundleIdentifier: bundleId))
            let appName = AppCatalog.shared.all.first { $0.bundleIdentifier == bundleId }?.name ?? bundleId
            return named.isEmpty
                ? .failed(reason: "\(appName) exposes nothing clickable")
                : .ok(reason: "Showing \(named.count) numbers in \(appName)")

        case .showHintsScoped(let rawKindName, let regionName):
            // A "?" prefix means the noun was not in any fixed list. Ask the
            // site's profile, then Jev; fall back to numbering everything,
            // which is at least never wrong, only noisy.
            var kindName = rawKindName
            if rawKindName.hasPrefix("?") {
                let noun = String(rawKindName.dropFirst())
                kindName = await Self.resolveGuideNoun(noun)?.rawValue ?? ""
            }
            let kind = HintScope.Kind(rawValue: kindName)
            let region = HintScope.Region(rawValue: regionName)
            let scoped = Hints.shared.refresh(scope: .focusedWindow, kind: kind, region: region)
            let what = [kind.map(\.rawValue), region.map { "the \($0.rawValue)" }]
                .compactMap { $0 }.joined(separator: " in ")
            return scoped.isEmpty
                ? .failed(reason: "Nothing matching \(what.isEmpty ? "that" : what) on screen")
                : .ok(reason: "Showing \(scoped.count) \(what.isEmpty ? "targets" : what)")

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

        case .showHintBox(let number):
            return Hints.shared.hint(number: number) == nil
                ? .failed(reason: "There is no number \(number)")
                : .ok(reason: "Outlining \(number)")

        case .showHints:
            let hints = Hints.shared.refresh()
            return hints.isEmpty
                ? .failed(reason: "Nothing on screen exposes anything clickable")
                : .ok(reason: "Showing \(hints.count) numbers")

        case .selectHint(let number):
            return Hints.shared.select(number)

        case .hideHints:
            Hints.shared.clear()
            return .ok(reason: "Numbers hidden")

        case .pointerAction(let kind):
            // "this" and "here" mean wherever the pointer is. The phone shows
            // it and lets you drag it, so pointing is a gesture and the words
            // stay short.
            return Pointer.perform(kind, at: Pointer.location())

        case .showForm:
            let fields = FormScanner.frontmostFields()
            guard !fields.isEmpty else {
                return .failed(reason: "Nothing fillable in the frontmost window")
            }
            guard let show = Self.onFormFound else {
                return .failed(reason: "No phone is connected to show it on")
            }
            _ = show
            // Only pays for a model call when the form left fields unnamed.
            let named = await FormScanner.nameUnlabelled(fields, apiKey: JevAPI.loadAPIKey())
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
            // Steps need a beat between them: focusing a field and typing into
            // it in the same instant races, and the text lands nowhere.
            for sub in steps {
                let result = await execute(sub, humanApproved: humanApproved)
                if result.status == .failed {
                    return .failed(reason: "\(label) stopped at “\(result.reason)”")
                }
                // A new tab or a freshly focused field needs longer to settle
                // than a plain keystroke does.
                let settle: Duration = {
                    if case .pressKeys(let spec) = sub,
                       spec.contains("cmd+t") || spec.contains("cmd+l") { return .milliseconds(320) }
                    return .milliseconds(140)
                }()
                try? await Task.sleep(for: settle)
            }
            return .ok(reason: label)

        case .pressButton(let requestId, let optionId):
            return await executeButtonPress(requestId: requestId, optionId: optionId)

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

    private func executeButtonPress(requestId: String, optionId: String) async -> ExecutionResult {
        guard let request = await store.get(id: requestId) else {
            return .failed(reason: "Request not found")
        }

        guard let option = request.options.first(where: { $0.id == optionId }) else {
            return .failed(reason: "Option not found in request")
        }

        guard !policy.dangerousButtonLabels.contains(where: { option.label.lowercased().contains($0.lowercased()) }) else {
            return .failed(reason: "Option label is dangerous and cannot be auto-pressed")
        }

        // A TCC consent sheet ignores synthetic input by design. Returning success
        // here would tell the phone the job was done while nothing happened.
        guard !request.handoffOnly else {
            return .failed(reason: "System permission dialog: macOS ignores synthetic clicks. Use the Screen Sharing handoff.")
        }

        guard let element = DialogRegistry.shared.element(for: requestId) else {
            return .failed(reason: "That dialog is no longer on screen — dismissed or expired.")
        }

        let presser = ButtonPresser(policy: policy)
        let result = presser.pressButton(in: element, withLabel: option.label)
        DialogRegistry.shared.discard(id: requestId)

        switch result {
        case .success(let message):
            return .ok(reason: message)
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
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return .ok(reason: "Command executed: \(output)")
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

        // Run self-tests
        var testFailures = SelfTest.run()
        // The push crypto is unverifiable from the outside — a wrong key
        // derivation just means a notification that never arrives — so it
        // round-trips against a local receiver at every launch.
        testFailures.append(contentsOf: runBlocking { await webPushSelfTest() })
        // What you say must keep meaning what it meant.
        testFailures.append(contentsOf: VocabularySelfTest.run())
        testFailures.append(contentsOf: CommandCodableSelfTest.run())
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
        JevLog.write("[jev] pairing dialog: device=\(device) serve=\(serveActive) url=\(pairingURL)")

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
