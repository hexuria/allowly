import Foundation
import AppKit
import JevCore

/// Turn a spoken sentence into something executable.
///
/// Deliberately small and literal. It recognises a verb and an app name and
/// nothing else; anything it does not understand is reported as not understood
/// rather than guessed at, because guessing here means launching or quitting
/// the wrong application.
enum VoiceCommand {
    private static let openVerbs = ["open", "launch", "start", "run", "switch to", "go to", "activate"]
    private static let quitVerbs = ["quit", "close", "kill", "exit", "stop"]
    private static let toggleVerbs = ["toggle", "show or hide", "flip"]
    private static let showVerbs = ["show", "summon", "bring up", "reveal", "bring back"]
    private static let hideVerbs = ["hide", "dismiss", "put away", "send away"]

    struct Parsed {
        let command: Command
        let description: String

        init(command: Command, description: String) {
            self.command = command
            self.description = description
        }
    }

    static func parse(_ transcript: String, catalog: AppCatalog = .shared) -> Parsed? {
        var text = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .lowercased()
        guard !text.isEmpty else { return nil }

        // "… N times" applies to anything, not just scrolling: "press escape
        // three times", "next tab twice", "scroll down 5 times". Strip the
        // count, parse what is left, then repeat it.
        if let (stripped, count) = repeatCount(in: text), count > 1 {
            text = stripped
            if let once = parse(text, catalog: catalog) {
                let steps = Array(repeating: once.command, count: count)
                return Parsed(command: .sequence(label: "\(once.description) ×\(count)", steps: steps),
                              description: "\(once.description) ×\(count)")
            }
            return nil
        }

        // Fixed phrases win over "verb + app name". Otherwise "show numbers"
        // resolves to the Numbers app and "show desktop" to anything called
        // Desktop — the literal vocabulary has to be checked first.
        if let parsed = Phrasebook.parse(text) { return parsed }

        // Directional verbs: "show terminal" should always show, not flip
        // it away when it happens to already be visible.
        if let remainder = strip(verbs: showVerbs, from: text),
           let app = catalog.resolve(spokenName: remainder),
           isRunning(app.bundleIdentifier) {
            return Parsed(command: .showApp(bundleIdentifier: app.bundleIdentifier),
                          description: "Show \(app.name)")
        }
        if let remainder = strip(verbs: hideVerbs, from: text),
           let app = catalog.resolve(spokenName: remainder),
           isRunning(app.bundleIdentifier) {
            return Parsed(command: .hideApp(bundleIdentifier: app.bundleIdentifier),
                          description: "Hide \(app.name)")
        }

        // Toggle before the others: "toggle Waz" is neither open nor quit.
        if let remainder = strip(verbs: toggleVerbs, from: text),
           let app = catalog.resolve(spokenName: remainder) {
            return Parsed(
                command: .toggleApp(bundleIdentifier: app.bundleIdentifier),
                description: "Toggle \(app.name)"
            )
        }

        // Quit before open: "close Mail" is a quit, not a request to open Mail.
        if let remainder = strip(verbs: quitVerbs, from: text),
           let app = catalog.resolve(spokenName: remainder) {
            return Parsed(
                command: .quitApp(bundleIdentifier: app.bundleIdentifier),
                description: "Quit \(app.name)"
            )
        }

        if let remainder = strip(verbs: openVerbs, from: text),
           let app = catalog.resolve(spokenName: remainder) {
            return Parsed(
                command: .launchApp(bundleIdentifier: app.bundleIdentifier),
                description: "Open \(app.name)"
            )
        }

        // Scrolling is unambiguous enough to handle without asking a model.
        for (phrase, direction) in [("scroll up", "up"), ("scroll down", "down"),
                                    ("scroll left", "left"), ("scroll right", "right"),
                                    ("page up", "up"), ("page down", "down")]
        where text.hasPrefix(phrase) {
            // "scroll down 10" means further, not ten separate scrolls.
            let tail = text.dropFirst(phrase.count).trimmingCharacters(in: .whitespaces)
            let token = tail.split(separator: " ").first.map(String.init) ?? ""
            let amount = Int(token) ?? spokenNumbers[token].flatMap { Int($0) } ?? 5
            return Parsed(command: .scroll(direction: direction, amount: min(amount, 50)),
                          description: amount == 5 ? "Scroll \(direction)"
                                                   : "Scroll \(direction) by \(amount)")
        }

        // The phrasebook handles the large literal vocabulary first: it is
        // deterministic, instant, and costs no model call.

        // "reset permissions" / "forget permissions" clears saved modes.
        if ["reset permissions", "forget permissions", "clear permissions",
            "reset approvals"].contains(where: { text.hasPrefix($0) }) {
            return Parsed(command: .runCommand(allowlistedPrefix: "__jev_reset", fullCommand: "__jev_reset"),
                          description: "Reset saved permissions")
        }

        // Keyboard shortcuts: "press escape", "press command q", "hit option 1".
        if let spec = Keystrokes.specFromSpokenPhrase(text) {
            return Parsed(command: .pressKeys(spec: spec), description: "Press \(spec)")
        }

        // Workspace navigation: "workspace 3", "go to workspace 3", "switch to
        // workspace 3". Spoken digits are handled because speech often writes
        // small numbers as words.
        if let workspace = workspaceId(in: text) {
            return Parsed(command: .switchWorkspace(id: workspace),
                          description: "Go to workspace \(workspace)")
        }

        // Bare app name with no verb means open. Say so explicitly in the
        // description: if a word was clipped off the front, "Open Notes (no
        // verb heard)" makes the misunderstanding visible instead of looking
        // like jev ignored you.
        if let app = catalog.resolve(spokenName: text) {
            return Parsed(
                command: .launchApp(bundleIdentifier: app.bundleIdentifier),
                description: "Open \(app.name) — no verb heard"
            )
        }

        return nil
    }

    /// Pull a trailing repeat count off a phrase. Capped: a misheard number
    /// should not be able to fire a hundred keystrokes.
    /// Show and hide govern something already on the machine. Starting an app
    /// is "open" or "launch"; treating "show X" as a launch made "show numbers"
    /// open a spreadsheet.
    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func repeatCount(in text: String) -> (String, Int)? {
        if text.hasSuffix(" twice") { return (String(text.dropLast(6)), 2) }
        if text.hasSuffix(" thrice") { return (String(text.dropLast(7)), 3) }

        for suffix in [" times", " time"] where text.hasSuffix(suffix) {
            let head = String(text.dropLast(suffix.count))
            guard let token = head.split(separator: " ").last.map(String.init) else { return nil }
            let value = Int(token) ?? spokenNumbers[token].flatMap { Int($0) }
            guard let value, value > 1 else { return nil }
            let remainder = head.dropLast(token.count).trimmingCharacters(in: .whitespaces)
            return (remainder, min(value, 20))
        }
        return nil
    }

    private static let spokenNumbers = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    /// Pull a workspace id out of phrases like "go to workspace three".
    /// Internal rather than private so the "go to" binding can ask whether
    /// this sentence is already claimed. See `Phrasebook.namesADestination`.
    static func workspaceId(in text: String) -> String? {
        guard let range = text.range(of: "workspace") else { return nil }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let token = tail.split(separator: " ").first.map(String.init) else { return nil }
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        if Int(cleaned) != nil { return cleaned }
        return spokenNumbers[cleaned]
    }

    /// Remove a leading verb and any filler article, returning what follows.
    private static func strip(verbs: [String], from text: String) -> String? {
        for verb in verbs where text.hasPrefix(verb + " ") {
            var rest = String(text.dropFirst(verb.count + 1))
            for filler in ["the ", "my ", "app ", "up "] where rest.hasPrefix(filler) {
                rest = String(rest.dropFirst(filler.count))
            }
            // Trailing "app": "open the notes app"
            if rest.hasSuffix(" app") { rest = String(rest.dropLast(4)) }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
