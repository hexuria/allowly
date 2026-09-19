import Foundation
import AppKit
import ApplicationServices
import JevCore
import JevAX
import JevDecide

/// Work out what a spoken sentence meant, using Jev when the literal parser
/// cannot tell.
///
/// The key idea: everything jev can act on is enumerable — the installed apps,
/// the buttons in the frontmost window — so the question put to Jev is always a
/// closed choice over things that really exist. Jev is a text-only classifier,
/// which is exactly the right shape for that, and it means no screenshot ever
/// has to be sent to a model.
enum JevIntent {
    struct IntentError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Resolution {
        let command: Command
        let description: String
        /// Lowest confidence across the answers this decision rests on.
        let confidence: Double
        /// Jev's calibrated view of whether this is safe to run unattended.
        let safety: Double
    }

    private static let operations = [
        "open_app", "quit_app", "toggle_app", "click_control", "type_text", "scroll",
        "known_capability", "unknown",
    ]

    static func resolve(transcript: String, alternatives: [String] = [],
                        apiKey: String) async -> Result<Resolution, IntentError> {
        let apps = AppCatalog.shared.all.map(\.name)
        let controls = frontmostControls().map(\.label)
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        var questions: [String: JevAPI.Question] = [
            "operation": .choice(
                instructions: "The user spoke a command to a Mac assistant. Which single operation are they asking for? 'toggle_app' means show it if hidden, hide it if in front.",
                labels: operations
            ),
            "safe": .noul(
                instructions: "Is this request safe to carry out immediately without asking the user to confirm?"
            ),
        // Hands free leaves the microphone open, so half of what arrives is
        // the room: a reply to someone, a video playing, thinking aloud. This
        // costs nothing — it rides on the call already being made — and it is
        // the difference between an assistant and a hazard.
        "addressed_to_the_mac": .noul(
                instructions: "Was this said as an instruction to the computer, rather than overheard speech — talking to another person, reading aloud, or a stray fragment?"
            ),
        ]
        // Only offer targets that exist. Asking Jev to pick from a list that
        // does not match the machine is how the old project produced answers
        // nothing could act on.
        questions["app"] = .choice(
            instructions: "Which application does this command act on? Choose 'none' if it does not name one.",
            labels: apps + ["none"]
        )
        // Hand Jev the whole capability catalog. It cannot invent a sequence,
        // but choosing among sequences that already exist is exactly what a
        // closed-choice classifier is for — so "close all tabs", "shut every
        // tab" and "get rid of the tabs" all land on the same workflow without
        // anyone enumerating synonyms.
        let capabilities = Phrasebook.catalog()
        questions["capability"] = .choice(
            instructions: "If the user is asking for one of these known actions, which one? Choose 'none' if none of them fits.",
            labels: capabilities + ["none"]
        )

        questions["scroll_direction"] = .choice(
            instructions: "If the user is asking to scroll, in which direction? Choose 'none' if they are not.",
            labels: ["up", "down", "left", "right", "none"]
        )
        if !controls.isEmpty {
            questions["control"] = .choice(
                instructions: "If the user is asking to click something in the frontmost window (\(frontmost)), which control do they mean? Choose 'none' otherwise.",
                labels: controls + ["none"]
            )
        }

        var state: [String: Any] = [
            "spoken": transcript,
            "frontmost_app": frontmost,
            "visible_controls": controls,
        ]
        // The readings speech recognition ranked lower. Nothing here parsed as
        // a command, so the top reading is already suspect — the words that
        // were actually said may only appear in one of these.
        if !alternatives.isEmpty {
            state["other_possible_readings"] = alternatives
        }

        JevLog.write("[jev] intent asking: frontmost=\(frontmost) controls=\(controls.count) \(controls.prefix(6).joined(separator: " | "))")
        let result = await JevAPI.ask(state: state, questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else {
            if case .failure(let error) = result { return .failure(IntentError("\(error)")) }
            return .failure(IntentError("no answer"))
        }

        let summary = answers.choices.map { "\($0.key)=\($0.value.choice)@\(String(format: "%.2f", $0.value.confidence))" }.sorted().joined(separator: " ")
        JevLog.write("[jev] intent answers: \(summary)")

        guard let operation = answers.choice("operation") else {
            return .failure(IntentError("Jev returned no operation"))
        }
        let safety = answers.noul("safe") ?? 0
        let addressed = answers.noul("addressed_to_the_mac") ?? 1
        if addressed < 0.35 {
            return .failure(IntentError("that did not sound like it was meant for the Mac"))
        }

        // A confident capability match wins over the coarser operation label:
        // it is more specific and it carries its own steps.
        if let capability = answers.choice("capability"),
           capability.choice != "none",
           capability.confidence >= 0.5,
           let parsed = Phrasebook.build(canonical: capability.choice) {
            return .success(Resolution(
                command: parsed.command,
                description: parsed.description,
                confidence: capability.confidence,
                safety: safety
            ))
        }

        switch operation.choice {
        case "open_app", "quit_app", "toggle_app":
            guard let appAnswer = answers.choice("app"), appAnswer.choice != "none",
                  let entry = AppCatalog.shared.resolve(spokenName: appAnswer.choice) else {
                return .failure(IntentError("Jev could not tell which app you meant"))
            }
            let command: Command
            let verb: String
            switch operation.choice {
            case "quit_app":
                command = .quitApp(bundleIdentifier: entry.bundleIdentifier); verb = "Quit"
            case "toggle_app":
                command = .toggleApp(bundleIdentifier: entry.bundleIdentifier); verb = "Toggle"
            default:
                command = .launchApp(bundleIdentifier: entry.bundleIdentifier); verb = "Open"
            }
            return .success(Resolution(
                command: command,
                description: "\(verb) \(entry.name)",
                confidence: min(operation.confidence, appAnswer.confidence),
                safety: safety
            ))

        case "click_control":
            guard let control = answers.choice("control"), control.choice != "none" else {
                return .failure(IntentError("Jev could not tell which control you meant"))
            }
            return .success(Resolution(
                command: .clickControl(label: control.choice),
                description: "Click “\(control.choice)” in \(frontmost)",
                confidence: min(operation.confidence, control.confidence),
                safety: safety
            ))

        case "scroll":
            let direction = answers.choice("scroll_direction")
            guard let direction, direction.choice != "none" else {
                return .failure(IntentError("Jev could not tell which way to scroll"))
            }
            return .success(Resolution(
                command: .scroll(direction: direction.choice, amount: 5),
                description: "Scroll \(direction.choice)",
                confidence: min(operation.confidence, direction.confidence),
                safety: safety
            ))

        case "type_text":
            return .success(Resolution(
                command: .typeText(text: transcript),
                description: "Type text into \(frontmost)",
                confidence: operation.confidence,
                safety: safety
            ))

        default:
            return .failure(IntentError("Jev did not recognise that as an action"))
        }
    }

    /// A control on screen, with where it is.
    struct Control: Codable, Sendable {
        let label: String
        let role: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Enumerate the frontmost window's actionable controls WITH geometry.
    /// Accessibility gives both the label and the frame, so "click Submit"
    /// needs no vision model and no screenshot — and pressing the element
    /// directly is more reliable than clicking a coordinate.
    static func frontmostControls(limit: Int = 80, roles: Set<String>? = nil) -> [Control] {
        guard AccessibilityPermission.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Chromium and Electron apps expose nothing to accessibility until
        // asked. Setting AXManualAccessibility switches their tree on, which is
        // the difference between "0 controls" and a usable window for Grok Bot,
        // VS Code, Slack, Discord and friends. Harmless on apps that ignore it.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var windowValue: AnyObject?
        let focusedStatus = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue)

        var root: AXUIElement?
        if focusedStatus == .success, let window = windowValue.map({ $0 as! AXUIElement }) {
            root = window
        } else {
            // Some apps expose no focused window but do have a window list.
            var windowsValue: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement], let first = windows.first {
                root = first
            }
        }

        guard let root else {
            JevLog.write("[jev] controls: \(app.localizedName ?? "?") exposes no window (focused status \(focusedStatus.rawValue))")
            return []
        }

        var out: [Control] = []
        var visited = 0

        // Page content first. A browser window is mostly browser: walking
        // depth-first from the window root spends the whole budget on the
        // toolbar before reaching anything the page put on screen. Starting
        // at the web area gives the budget to what you are actually looking at.
        if let webArea = findWebArea(root, depth: 0, visited: &visited) {
            collectControls(webArea, into: &out, depth: 0, limit: limit,
                            roles: roles, visited: &visited)
        }
        if out.count < limit {
            collectControls(root, into: &out, depth: 0, limit: limit,
                            roles: roles, visited: &visited)
        }

        // The same element can be reached through both walks.
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.role)|\($0.label)|\($0.x)|\($0.y)").inserted }

        JevLog.write("[jev] controls: \(app.localizedName ?? "?") -> \(out.count)"
            + (roles == nil ? "" : " matching \(roles!.sorted().joined(separator: "/"))"))
        return out
    }

    /// The root of the rendered page inside a browser or Electron window.
    private static func findWebArea(_ element: AXUIElement, depth: Int,
                                    visited: inout Int) -> AXUIElement? {
        guard depth < 12, visited < maxNodes else { return nil }
        visited += 1
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        if (roleValue as? String) == "AXWebArea" { return element }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findWebArea(child, depth: depth + 1, visited: &visited) { return found }
        }
        return nil
    }

    /// Bring an app's dropdown panel to the front, if it has one.
    ///
    /// Activating an app is not the same as showing the window you meant. A
    /// quake-style terminal keeps two windows — an ordinary one and a floating
    /// panel — and activation surfaces whichever the app prefers, which is how
    /// "show waz" kept producing a second terminal instead of the dropdown.
    /// The panel is identifiable: the app marks it `AXSystemDialog` or
    /// `AXFloatingWindow`, and the window server puts it on a raised layer.
    ///
    /// Returns true when a panel was found and raised.
    @discardableResult
    static func raisePanel(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return false }

        let panelSubroles: Set<String> = ["AXSystemDialog", "AXFloatingWindow", "AXDialog"]
        guard let panel = windows.first(where: { window in
            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            return panelSubroles.contains(subroleValue as? String ?? "")
        }) else { return false }

        guard AXUIElementPerformAction(panel, kAXRaiseAction as CFString) == .success else { return false }
        AXUIElementSetAttributeValue(panel, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(panel, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// A row often has no title of its own; its label is the text inside it.
    private static func descendantText(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleValue)
            if let text = (titleValue as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
            var valueValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueValue)
            if let text = (valueValue as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
            if let nested = descendantText(child, depth: depth + 1) { return nested }
        }
        return nil
    }

    /// How deep to walk. Measured, not guessed: on a real page in Chrome the
    /// shallowest links sit around depth 30 and the deepest at 38, under 1800
    /// nested AXGroups. The old cap of 14 never reached web content at all —
    /// it only ever saw the browser's own toolbar, which is why numbering the
    /// page and clicking anything on it by name have never worked in a browser.
    private static let maxDepth = 45

    /// Nodes to examine before giving up, so a pathological tree cannot hang
    /// the walk now that it is allowed to go deep.
    private static let maxNodes = 12000

    private static func collectControls(_ element: AXUIElement, into out: inout [Control],
                                        depth: Int, limit: Int,
                                        roles: Set<String>? = nil,
                                        visited: inout Int) {
        guard depth < maxDepth, out.count < limit, visited < maxNodes else { return }
        visited += 1

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        // Rows, cells and headings matter as much as buttons: sidebar items
        // like "Master Tester" are AXRow/AXStaticText, and excluding them meant
        // half of every real app was invisible to Jev.
        // AXRow and AXCell are structural: a file list reports a row, its
        // cells and its label, so one file consumed four numbers and the real
        // controls fell off the end of the cap.
        let actionable = [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXLink", "AXTextField", "AXTextArea", "AXStaticText",
            "AXTab", "AXDisclosureTriangle", "AXImage", "AXMenuButton",
        ]
        if actionable.contains(role), roles.map({ $0.contains(role) }) ?? true {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
            var descValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
            var valueValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueValue)
            let label = (titleValue as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? (descValue as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? (valueValue as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? descendantText(element)

            if let label {
                var frame = CGRect.zero
                var positionValue: AnyObject?
                var sizeValue: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
                   AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                    frame = CGRect(origin: point, size: size)
                }
                out.append(Control(label: label, role: role,
                                   x: frame.origin.x, y: frame.origin.y,
                                   width: frame.width, height: frame.height))
            }
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            collectControls(child, into: &out, depth: depth + 1, limit: limit,
                            roles: roles, visited: &visited)
        }
    }

}

// MARK: - Actions

extension JevIntent {
    /// Press a control in the frontmost window by its label.
    static func clickFrontmostControl(labelled label: String) -> ExecutionResult {
        guard AccessibilityPermission.isTrusted() else {
            return .failed(reason: "Accessibility is not granted")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failed(reason: "No frontmost application")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue.map({ $0 as! AXUIElement }) else {
            return .failed(reason: "No focused window in \(app.localizedName ?? "that app")")
        }
        guard let target = find(in: window, titled: label, depth: 0) else {
            return .failed(reason: "No control called “\(label)” on screen")
        }
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        return status == .success
            ? .ok(reason: "Clicked “\(label)”")
            : .failed(reason: "Could not press “\(label)” (AX \(status.rawValue))")
    }

    /// Type text into whatever has keyboard focus.
    static func typeIntoFrontmost(_ text: String) -> ExecutionResult {
        guard AccessibilityPermission.isTrusted() else {
            return .failed(reason: "Accessibility is not granted")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }
        var posted = 0
        for chunk in text.chunked(into: 16) {
            // BOTH halves are required. Posting only the key-down leaves the
            // event unmatched and browsers discard it silently — which is why
            // a new tab opened and nothing was ever typed into it.
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            var utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            posted += chunk.count
            // A short gap: posting chunks back to back outruns some text views.
            Thread.sleep(forTimeInterval: 0.012)
        }

        guard posted == text.count else {
            return .failed(reason: "Only \(posted) of \(text.count) characters could be sent")
        }
        return .ok(reason: "Typed \(text.count) characters")
    }

    private static func find(in element: AXUIElement, titled label: String, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        if let title = titleValue as? String, title.caseInsensitiveCompare(label) == .orderedSame {
            return element
        }
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let hit = find(in: child, titled: label, depth: depth + 1) { return hit }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(size, count - offset))
            return String(self[start..<end])
        }
    }
}

// MARK: - Pointer and gestures

extension JevIntent {
    /// Click at a screen coordinate. The fallback for surfaces accessibility
    /// cannot see into — canvas, some Electron apps, remote desktops. Pressing
    /// a named control is preferred wherever it is available, because a
    /// coordinate goes stale the moment anything moves.
    static func click(x: Double, y: Double) -> ExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return .failed(reason: "Could not synthesise a click")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok(reason: "Clicked at \(Int(x)), \(Int(y))")
    }

    /// Scroll the surface under the pointer.
    static func scroll(direction: String, amount: Int) -> ExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }
        let steps = max(1, min(amount, 50))
        let magnitude: Int32
        var horizontal = false
        switch direction.lowercased() {
        case "up": magnitude = Int32(steps)
        case "down": magnitude = Int32(-steps)
        case "left": magnitude = Int32(steps); horizontal = true
        case "right": magnitude = Int32(-steps); horizontal = true
        default: return .failed(reason: "Unknown scroll direction “\(direction)”")
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: horizontal ? 2 : 1,
            wheel1: horizontal ? 0 : magnitude,
            wheel2: horizontal ? magnitude : 0,
            wheel3: 0
        ) else {
            return .failed(reason: "Could not synthesise a scroll")
        }
        event.post(tap: .cghidEventTap)
        return .ok(reason: "Scrolled \(direction)")
    }
}

extension JevIntent {
    /// Right-click a named control, at the centre of where accessibility says
    /// it is. There is no AX "show context menu" action, so this is one of the
    /// few places a synthetic pointer event is genuinely required.
    static func rightClickFrontmostControl(labelled label: String) -> ExecutionResult {
        let matches = frontmostControls().filter {
            $0.label.caseInsensitiveCompare(label) == .orderedSame
        }
        let target = matches.first ?? frontmostControls().first {
            $0.label.lowercased().contains(label.lowercased())
        }
        guard let target, target.width > 0, target.height > 0 else {
            return .failed(reason: "No control called “\(label)” on screen")
        }

        let point = CGPoint(x: target.x + target.width / 2, y: target.y + target.height / 2)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                                 mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                               mouseCursorPosition: point, mouseButton: .right) else {
            return .failed(reason: "Could not synthesise a right click")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok(reason: "Right clicked “\(target.label)”")
    }
}

extension JevIntent {
    /// Put text into a named field.
    ///
    /// Setting AXValue directly is preferred over typing: it is atomic, it
    /// cannot be mangled by autocomplete or a slow keystroke race, and nothing
    /// is posted to the global event stream. Some web fields ignore a direct
    /// value set, so typing is the fallback.
    static func fill(field label: String, with text: String) -> ExecutionResult {
        guard AccessibilityPermission.isTrusted() else {
            return .failed(reason: "Accessibility is not granted")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failed(reason: "No frontmost application")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue.map({ $0 as! AXUIElement }) else {
            return .failed(reason: "No focused window")
        }
        guard let field = findTextField(in: window, matching: label, depth: 0) else {
            return .failed(reason: "No field called “\(label)” on screen")
        }

        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let status = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFTypeRef)
        if status == .success {
            return .ok(reason: "Filled “\(label)”")
        }
        // The field refused a direct set, so type into it instead.
        let typed = typeIntoFrontmost(text)
        return typed.status == .ok
            ? .ok(reason: "Typed into “\(label)”")
            : .failed(reason: "Could not fill “\(label)”")
    }

    /// Match a text field by title, description, or placeholder — web forms
    /// label their inputs in whichever of those the framework felt like.
    private static func findTextField(in element: AXUIElement, matching label: String,
                                      depth: Int) -> AXUIElement? {
        guard depth < 16 else { return nil }
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"].contains(role) {
            let attributes: [String] = [
                kAXTitleAttribute as String,
                kAXDescriptionAttribute as String,
                kAXPlaceholderValueAttribute as String,
                "AXHelp",
            ]
            for attribute in attributes {
                var value: AnyObject?
                AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                if let text = value as? String,
                   text.lowercased().contains(label.lowercased()) {
                    return element
                }
            }
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let hit = findTextField(in: child, matching: label, depth: depth + 1) { return hit }
        }
        return nil
    }
}

extension JevIntent {
    /// Right click at a screen coordinate, for taps held on the screen view.
    static func rightClick(x: Double, y: Double) -> ExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                                 mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                               mouseCursorPosition: point, mouseButton: .right) else {
            return .failed(reason: "Could not synthesise a right click")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .ok(reason: "Right clicked at \(Int(x)), \(Int(y))")
    }
}

extension JevIntent {
    /// Is this process drawing anything on screen right now?
    ///
    /// Asked of the window server, not accessibility. AXWindows comes back
    /// empty once an app is hidden even when a floating panel is still on
    /// screen, and NSRunningApplication.isHidden reports the same fiction.
    /// CGWindowList only lists what is genuinely being displayed.
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else { continue }
            // Ignore the one-pixel helper windows some apps keep around.
            if width > 20 && height > 20 { return true }
        }
        return false
    }

    /// Ask the frontmost window of a process to close itself.
    @discardableResult
    static func dismissFrontWindow(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else { return false }

        if AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success { return true }

        var closeButton: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
           let button = closeButton {
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
        }
        return false
    }
}

extension JevIntent {
    /// The frontmost app's menu bar: File, Edit, View, Go and the rest.
    ///
    /// These hang off the application element, not off any window, which is
    /// why walking the focused window never found them.
    static func frontmostMenuBarItems() -> [Control] {
        guard AccessibilityPermission.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue.map({ $0 as! AXUIElement }) else { return [] }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement] else { return [] }

        return items.compactMap { item in
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue)
            guard let title = (titleValue as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { return nil }

            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue) == .success else {
                return nil
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            guard size.width > 4, size.height > 4 else { return nil }

            return Control(label: title, role: "AXMenuBarItem",
                           x: point.x, y: point.y, width: size.width, height: size.height)
        }
    }

    /// Sort into reading order: top to bottom, left to right within a row.
    ///
    /// The tree walk returns depth-first order, which to a person looks
    /// arbitrary — number 12 could be anywhere. Banding by Y first makes the
    /// numbering follow how the window is actually read.
    static func inReadingOrder(_ controls: [Control], bandHeight: Double = 24) -> [Control] {
        controls.sorted { a, b in
            let bandA = (a.y / bandHeight).rounded(.down)
            let bandB = (b.y / bandHeight).rounded(.down)
            if bandA != bandB { return bandA < bandB }
            return a.x < b.x
        }
    }
}

extension JevIntent {
    /// Controls belonging to visible windows of apps other than the frontmost.
    ///
    /// Only for the explicit "everywhere" scope: with a tiling manager the
    /// user really can see several windows at once, and restricting numbers to
    /// the focused one would leave most of the screen unaddressable.
    static func controlsInOtherVisibleApps(limit: Int) -> [Control] {
        guard AccessibilityPermission.isTrusted() else { return [] }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // The window server is the authority on what is actually displayed.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var pids = Set<pid_t>()
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != frontPid,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 120, height > 80 else { continue }
            pids.insert(pid)
        }

        var out: [Control] = []
        for pid in pids where out.count < limit {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windowsValue: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let axWindows = windowsValue as? [AXUIElement], let window = axWindows.first else { continue }
            var found: [Control] = []
            var visited = 0
            collectControls(window, into: &found, depth: 0, limit: limit - out.count,
                            visited: &visited)
            out += found.filter { $0.width > 4 && $0.height > 4 }
        }
        return out
    }
}
