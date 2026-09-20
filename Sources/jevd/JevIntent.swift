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
        "known_capability", "web_task", "unknown",
    ]

    /// - Parameter controls: the labels of what is actually on screen, read by
    ///   Cua Driver. Passed in rather than looked up here so the resolver has
    ///   no opinion about *how* the Mac is observed — and so the closed choice
    ///   it hands Jev can only ever name a control the driver just confirmed.
    static func resolve(transcript: String, alternatives: [String] = [],
                        frontmostApp: String?,
                        controls: [String],
                        apiKey: String) async -> Result<Resolution, IntentError> {
        let apps = AppCatalog.shared.all.map(\.name)
        // Whoever supplied the controls also says which app they came from,
        // so the name and the buttons always describe the same window.
        let frontmost = frontmostApp
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "unknown"

        var questions: [String: JevAPI.Question] = [
            "operation": .choice(
                instructions: "The user spoke a command to a Mac assistant. Which single operation are they asking for? 'toggle_app' means show it if hidden, hide it if in front. 'web_task' means carrying out a goal on a website — searching a site, playing something, opening a result — as opposed to 'type_text', which types the words themselves wherever the cursor already is.",
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

        // A control you can see beats a shortcut you cannot.
        //
        // Two ways this went wrong, both real:
        //
        //   "click the Approve Invoice button" → the capability "click this"
        //   won on confidence and clicked wherever the pointer happened to be,
        //   with the control named at 0.98. A press of whatever is under the
        //   pointer is the least specific thing available.
        //
        //   "click skip", with a Skip button on screen → the capability "skip"
        //   won and sent the media key for *next track*, changing the music in
        //   a different application entirely.
        //
        // The rule that covers both: if the person used a pressing verb and we
        // can name a control they can see, that is what they meant. A global
        // shortcut is the fallback for when they did not point at anything.
        let namedControl = answers.choice("control").flatMap {
            $0.choice != "none" && $0.confidence >= 0.5 ? $0 : nil
        }
        let spokenAsAPress = Self.startsWithPressVerb(transcript)
        let preferNamedControl = namedControl != nil
            && (operation.choice == "click_control" || spokenAsAPress)

        // A confident capability match wins over the coarser operation label:
        // it is more specific and it carries its own steps.
        if let capability = answers.choice("capability"),
           capability.choice != "none",
           capability.confidence >= 0.5,
           // ...but not over a web task. "play blinding lights on youtube"
           // matches the "play" capability, which is the F8 media key — a
           // single keystroke that cannot carry out a goal on a website. The
           // capability is more specific about the verb and completely wrong
           // about the intent.
           operation.choice != "web_task",
           let parsed = Phrasebook.build(canonical: capability.choice),
           // A pointer press never outranks a named control; and when the
           // words were a press, nothing else does either.
           !(preferNamedControl && (Self.isPointerAction(parsed.command) || spokenAsAPress)) {
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

        case "web_task":
            // A floor, matching the one JevDecider uses. Measured: "new tab"
            // classifies as web_task at 0.31 — wrong, though harmless in
            // practice because the Phrasebook claims those words long before
            // this resolver runs. Relying on that ordering would be relying on
            // something several files away, so the weak answer is refused here
            // too. Strong ones measure 1.00.
            guard operation.confidence >= 0.6 else {
                return .failure(IntentError("Jev did not recognise that as an action"))
            }
            // The goal is the sentence. The starting page is resolved later,
            // by jev, from a site named in those words or the page already
            // open — never from anything a model produced.
            return .success(Resolution(
                command: .webTask(goal: transcript),
                description: "Carry out “\(transcript)” in your browser",
                confidence: operation.confidence,
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

    /// Whether a command just presses wherever the pointer already is.
    private static func isPointerAction(_ command: Command) -> Bool {
        if case .pointerAction = command { return true }
        return false
    }

    /// Did they ask for something to be pressed, rather than naming a
    /// shortcut? "click skip" is a press; "skip" on its own is not.
    static func startsWithPressVerb(_ transcript: String) -> Bool {
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["click", "press", "tap", "push", "hit", "choose", "select"]
            .contains { text.hasPrefix($0 + " ") }
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


    /// How deep to walk. Measured, not guessed: on a real page in Chrome the
    /// shallowest links sit around depth 30 and the deepest at 38, under 1800
    /// nested AXGroups. The old cap of 14 never reached web content at all —
    /// it only ever saw the browser's own toolbar, which is why numbering the
    /// page and clicking anything on it by name have never worked in a browser.
    private static let maxDepth = 45

    /// Nodes to examine before giving up, so a pathological tree cannot hang
    /// the walk now that it is allowed to go deep.
    private static let maxNodes = 12000


}

// MARK: - Actions

extension JevIntent {


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

}

extension JevIntent {
}

extension JevIntent {

}

extension JevIntent {
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
           let button = closeButton,
           // Checked, not asserted. `as!` on an attribute the app fills
           // in takes the daemon down if it ever holds anything else.
           CFGetTypeID(button as CFTypeRef) == AXUIElementGetTypeID() {
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
        }
        return false
    }
}

extension JevIntent {

}

extension JevIntent {
}
