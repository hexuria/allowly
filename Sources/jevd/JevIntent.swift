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
        /// Jev's view of whether this can run unattended, asked in the same
        /// breath as "what is it" so the auto policy need not ask again.
        let verdict: SafetyVerdict
    }

    private static let operations = [
        "open_app", "quit_app", "toggle_app", "click_control", "type_text", "scroll",
        "known_capability", "open_url", "web_task", "fill_detail", "switch_workspace", "unknown",
    ]

    /// - Parameter controls: the labels of what is actually on screen, read by
    ///   Cua Driver. Passed in rather than looked up here so the resolver has
    ///   no opinion about *how* the Mac is observed — and so the closed choice
    ///   it hands Jev can only ever name a control the driver just confirmed.
    static func resolve(transcript: String, alternatives: [String] = [],
                        frontmostApp: String?,
                        controls: [String],
                        context: Phrasebook.Context? = nil,
                        runningApps: Set<String> = [],
                        workspaces: [String] = [],
                        apiKey: String) async -> Result<Resolution, IntentError> {
        let apps = AppCatalog.shared.all.map(\.name)
        // Whoever supplied the controls also says which app they came from,
        // so the name and the buttons always describe the same window.
        let frontmost = frontmostApp
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "unknown"

        var questions: [String: JevAPI.Question] = [
            "operation": .choice(
                instructions: "The user spoke a command to a Mac assistant. Which single operation are they asking for? 'toggle_app' means show it if hidden, hide it if in front. 'open_url' means they only named a website to open and nothing more. 'web_task' means they want something DONE on a website — searching it, playing something, opening a result — not merely opening it. 'type_text' types the words themselves wherever the cursor already is. 'fill_detail' means typing one of the personal details already saved on this Mac — an email address, a phone number, a tax number — which the user refers to by name rather than saying the value. 'switch_workspace' means going to a numbered workspace or desktop.",
                labels: operations
            ),
            // The same two questions the auto policy used to ask in a second
            // round trip once the sentence was resolved. Asked here, on the
            // call already being made, they cost nothing and the policy
            // reuses them — one judgement instead of two that could disagree.
            "routine": .noul(instructions: SafetyVerdict.routineQuestion),
            "destructive": .noul(instructions: SafetyVerdict.destructiveQuestion),
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
        // Quitting, hiding and toggling act on something that is RUNNING.
        // Offering every installed app for those, as `app` does, invited a
        // confident pick of something with no process — and the speech hints
        // already rank running apps first for exactly this reason.
        if !runningApps.isEmpty {
            questions["running_app"] = .choice(
                instructions: "If the user is asking to quit, hide, show or switch to an app that is currently running, which one? Choose 'none' otherwise.",
                labels: runningApps.sorted() + ["none"]
            )
        }
        // A closed choice over the workspaces that exist, from the window
        // manager. Nothing is offered when none can be listed.
        if !workspaces.isEmpty {
            questions["workspace"] = .choice(
                instructions: "If the user is asking to go to a workspace or desktop, which one? Choose 'none' otherwise.",
                labels: workspaces + ["none"]
            )
        }
        // Hand Jev the whole capability catalog. It cannot invent a sequence,
        // but choosing among sequences that already exist is exactly what a
        // closed-choice classifier is for — so "close all tabs", "shut every
        // tab" and "get rid of the tabs" all land on the same workflow without
        // anyone enumerating synonyms.
        let capabilities = Phrasebook.catalog(in: context)
        questions["capability"] = .choice(
            instructions: "If the user is asking for one of these known actions, which one? Choose 'none' if none of them fits.",
            labels: capabilities + ["none"]
        )

        // Only what is actually saved. Offering a field nobody filled in gets
        // a confident answer and nothing to type — and the list is names, so
        // no value is ever part of a question.
        let details = PersonalDetails.saved()
        if !details.isEmpty {
            questions["detail"] = .choice(
                instructions: "If the user is asking to fill in one of their saved personal details, which one? Choose 'none' otherwise.",
                labels: details + ["none"]
            )
        }

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

        JevLog.write("[allowly] intent asking: frontmost=\(frontmost) controls=\(controls.count) \(controls.prefix(6).joined(separator: " | "))")
        let result = await JevAPI.ask(state: state, questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else {
            if case .failure(let error) = result { return .failure(IntentError("\(error)")) }
            return .failure(IntentError("no answer"))
        }

        let summary = answers.choices.map { "\($0.key)=\($0.value.choice)@\(String(format: "%.2f", $0.value.confidence))" }.sorted().joined(separator: " ")
        JevLog.write("[allowly] intent answers: \(summary)")

        // Every answer is checked against exactly what its question offered
        // before it is believed. An unsound reply — a choice outside the set,
        // a distribution over different keys, numbers that do not sum to one
        // — is read as no answer, which is what it is. The browser loop has
        // done this since it was written; this resolver did not, and it is
        // the code that decides whether to open a URL or hand a signed-in
        // shop to an agent.
        func sound(_ name: String) -> JevAPI.ChoiceAnswer? {
            answers.soundChoice(name, offered: questions[name]?.offeredLabels)
        }
        guard let operation = sound("operation") else {
            return .failure(IntentError("Jev returned no usable operation"))
        }
        let verdict = SafetyVerdict(routine: answers.noul("routine") ?? 0,
                                    destructive: answers.noul("destructive") ?? 1)
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
        // Decisive, not merely above a number. A flat 0.5 rejected the
        // correct control among sixty candidates and accepted a coin flip
        // between two; the runner-up margin means the same thing at any size.
        let namedControl = sound("control").flatMap {
            $0.choice != "none" && $0.isDecisive ? $0 : nil
        }
        let spokenAsAPress = Self.startsWithPressVerb(transcript)
        let preferNamedControl = namedControl != nil
            && (operation.choice == "click_control" || spokenAsAPress)

        // A confident capability match wins over the coarser operation label:
        // it is more specific and it carries its own steps.
        if let capability = sound("capability"),
           capability.choice != "none",
           capability.isDecisive,
           // ...but not over a web task. "play blinding lights on youtube"
           // matches the "play" capability, which is the F8 media key — a
           // single keystroke that cannot carry out a goal on a website. The
           // capability is more specific about the verb and completely wrong
           // about the intent.
           operation.choice != "web_task",
           let parsed = Phrasebook.build(canonical: capability.choice, in: context),
           // A pointer press never outranks a named control; and when the
           // words were a press, nothing else does either.
           !(preferNamedControl && (Self.isPointerAction(parsed.command) || spokenAsAPress)) {
            return .success(Resolution(
                command: parsed.command,
                description: parsed.description,
                confidence: capability.confidence,
                verdict: verdict
            ))
        }

        // Said as a press, with something on screen that matches: click it.
        //
        // `preferNamedControl` already existed and was only used to stop a
        // capability shortcut stealing a press. It never overrode the coarser
        // operation label, and that gap is what this is fixing. Measured, on
        // a real Amazon page: "click free shipping to philippines" resolved
        // `control=Free Shipping Zone@0.78` — the right link, named correctly
        // from words that do not appear in its label — alongside
        // `operation=web_task@0.57`. The web-task floor then refused the
        // whole thing while the correct answer sat in the same reply.
        //
        //
        // Generalised since: a control the model named decisively beats an
        // operation it could not decide on, whether or not a press verb was
        // said. "click free shipping to philippines" was refused at
        // operation=web_task@0.57 with control=Free Shipping Zone@0.78 in the
        // same reply — the right answer, thrown away with the weak one. A
        // decisive operation still wins, so "go to youtube and search hello"
        // at 1.00 is not stolen by whatever button happens to be on screen.
        if let control = namedControl,
           spokenAsAPress || !operation.isDecisive {
            return .success(Resolution(
                command: .clickControl(label: control.choice),
                description: "Click “\(control.choice)” in \(frontmost)",
                confidence: control.confidence,
                verdict: verdict
            ))
        }

        switch operation.choice {
        case "switch_workspace":
            guard let workspace = sound("workspace"), workspace.choice != "none" else {
                return .failure(IntentError("Jev could not tell which workspace you meant"))
            }
            return .success(Resolution(
                command: .switchWorkspace(id: workspace.choice),
                description: "Go to workspace \(workspace.choice)",
                confidence: min(operation.confidence, workspace.confidence),
                verdict: verdict
            ))

        case "open_app", "quit_app", "toggle_app":
            // Running first for the verbs that need a process, installed for
            // launching; each falls back to the other list.
            let preferRunning = operation.choice != "open_app"
            let ordered = preferRunning ? ["running_app", "app"] : ["app", "running_app"]
            let appAnswer = ordered.lazy.compactMap { sound($0) }.first { $0.choice != "none" }
            guard let appAnswer,
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
                verdict: verdict
            ))

        case "click_control":
            guard let control = answers.choice("control"), control.choice != "none" else {
                return .failure(IntentError("Jev could not tell which control you meant"))
            }
            return .success(Resolution(
                command: .clickControl(label: control.choice),
                description: "Click “\(control.choice)” in \(frontmost)",
                confidence: min(operation.confidence, control.confidence),
                verdict: verdict
            ))

        case "scroll":
            let direction = sound("scroll_direction")
            guard let direction, direction.choice != "none" else {
                return .failure(IntentError("Jev could not tell which way to scroll"))
            }
            return .success(Resolution(
                command: .scroll(direction: direction.choice, amount: 5),
                description: "Scroll \(direction.choice)",
                confidence: min(operation.confidence, direction.confidence),
                verdict: verdict
            ))

        case "fill_detail":
            guard let detail = sound("detail"), detail.choice != "none" else {
                return .failure(IntentError("Jev could not tell which detail you meant"))
            }
            // The NAME travels; the value is fetched by the executor at the
            // moment it types it.
            return .success(Resolution(
                command: .fillDetail(name: detail.choice),
                description: "Type your \(PersonalDetails.canonicalName(detail.choice))",
                confidence: min(operation.confidence, detail.confidence),
                verdict: verdict
            ))

        case "open_url":
            // The model said this names a place. The address is built from
            // what the person said, here, rather than returned by the model.
            guard let destination = Phrasebook.destination(fromSpoken: transcript) else {
                return .failure(IntentError("Jev could not tell which site you meant"))
            }
            return .success(Resolution(
                command: .openURL(url: "https://" + destination),
                description: "Open \(destination)",
                confidence: operation.confidence,
                verdict: verdict
            ))

        case "web_task":
            // A floor, matching the one JevDecider uses. Measured: "new tab"
            // classifies as web_task at 0.31 — wrong, though harmless in
            // practice because the Phrasebook claims those words long before
            // this resolver runs. Relying on that ordering would be relying on
            // something several files away, so the weak answer is refused here
            // too. Strong ones measure 1.00.
            // No floor here any more. One sat at 0.6 inside an outer gate of
            // 0.55 (Runtime.swift, the intent route), so a web task the outer
            // gate would merely have ASKED about was refused outright — with
            // the correct control sitting in the same reply. An undecided
            // operation is now handled above by preferring a decisive control;
            // what reaches here is either decisive or the best there is, and a
            // web task is forced to a card regardless unless the policy says
            // always, so the person is the gate, not a number.
            // The goal is the sentence. The starting page is resolved later,
            // by jev, from a site named in those words or the page already
            // open — never from anything a model produced.
            return .success(Resolution(
                command: .webTask(goal: transcript),
                description: "Carry out “\(transcript)” in your browser",
                confidence: operation.confidence,
                verdict: verdict
            ))

        case "type_text":
            return .success(Resolution(
                command: .typeText(text: transcript),
                description: "Type text into \(frontmost)",
                confidence: operation.confidence,
                verdict: verdict
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

/// Whether an action may run without a card, in Jev's calibrated view.
///
/// Two numbers rather than one "safe": asking whether the action is routine
/// AND whether it could be hard to undo gives usable signal where a single
/// "is this safe?" deferred on everything, including "scroll down".
struct SafetyVerdict: Sendable, Equatable {
    let routine: Double
    let destructive: Double

    static let routineQuestion =
        "A Mac assistant has been asked to do this by its owner. Is it a routine, low-risk, easily reversible action that the assistant should simply carry out?"
    static let destructiveQuestion =
        "Could this destroy data, send a message, spend money, change a security setting, or otherwise be hard to undo?"

    /// Run it when Jev thinks it is routine and not destructive. Either
    /// doubt goes to the person: the asymmetry is the whole safety argument.
    var allowsUnattended: Bool { routine >= 0.6 && destructive <= 0.4 }

    /// Jev calls it hard to undo: whatever the policy, a person decides.
    var looksDestructive: Bool { destructive > 0.5 }
}
