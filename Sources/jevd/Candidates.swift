import Foundation
import JevCore

/// Where a sentence is resolved: from the cursor outward.
///
/// Precedence used to be a line number. Nine rungs ran top to bottom and the
/// first that recognised the words won, so a stage that knew nothing about
/// the screen answered before one that did, and every fix taught one rung the
/// grammar of another — the "go to" binding calling the workspace parser to
/// ask permission, the control matcher calling the phrasebook. Meaning
/// depends on where you are, and the order has to say so in one place.
///
/// So every stage now PROPOSES a candidate tagged with the scope it came
/// from, and one comparison chooses: the innermost exact claim wins. That is
/// the order macOS itself resolves a keystroke — first responder outward —
/// and it is the order the person means: what is under the cursor, then
/// what is in the window, then what is on this monitor, then the workspace,
/// then everything.
enum Candidates {

    enum Level: Int, Comparable, Sendable {
        case cursor = 0, window, monitor, workspace, global
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var route: String {
            switch self {
            case .cursor: return "screen/cursor"
            case .window: return "screen/window"
            case .monitor: return "monitor"
            case .workspace: return "workspace"
            case .global: return "vocabulary"
            }
        }
    }

    struct Candidate: Sendable {
        let parsed: VoiceCommand.Parsed
        let level: Level
        /// What to journal. `vocabulary` keeps its effect check.
        var route: String { level.route }
    }

    /// The one comparison.
    ///
    /// `onScreen` is the control matcher's answer: an exact, unique label on
    /// screen that no global phrase claims. `parsed` is the global vocabulary
    /// and the local parsers. Both are computed by the caller because one is
    /// async and neither should be computed twice.
    ///
    /// One deliberate asymmetry, kept from the history this replaces: with
    /// no pressing verb, a global phrase beats a bare on-screen match.
    /// "save" is ⌘S even when a Save button is showing; "click save" is the
    /// button. Letting the screen win outright was measured to steal "save",
    /// "back", "find" and "copy" from the vocabulary, and the press verb is
    /// how the person says which they meant. So the window level is inner
    /// only when they pointed at it with a verb; otherwise it bubbles up
    /// past global and is offered last, by the caller, as a bare match.
    static func choose(text: String, scope: Scope, pressed: Bool,
                       onScreen: String?, parsed: VoiceCommand.Parsed?) -> Candidate? {
        // Cursor: the words name the control the pointer is on. Innermost.
        if let under = scope.underPointer, !under.isEmpty,
           namesExactly(text, under, pressed: pressed) {
            return Candidate(parsed: VoiceCommand.Parsed(command: .clickControl(label: under),
                                                         description: "Click “\(under)”"),
                             level: .cursor)
        }
        // Window, when pointed at with a verb.
        if pressed, let label = onScreen {
            return Candidate(parsed: VoiceCommand.Parsed(command: .clickControl(label: label),
                                                         description: "Click “\(label)”"),
                             level: .window)
        }
        // Workspace: a numbered workspace that exists, before any global
        // phrase can turn the same words into something else.
        if let id = VoiceCommand.workspaceId(in: text.lowercased()),
           scope.workspaces.isEmpty || scope.workspaces.contains(id) {
            return Candidate(parsed: VoiceCommand.Parsed(command: .switchWorkspace(id: id),
                                                         description: "Go to workspace \(id)"),
                             level: .workspace)
        }
        // Global: the vocabulary and the local parsers.
        if let parsed { return Candidate(parsed: parsed, level: .global) }
        return nil
    }

    /// Whether the words are exactly this label, allowing a leading press
    /// verb. "click free shipping zone" names "Free Shipping Zone";
    /// "free shipping" does not.
    static func namesExactly(_ text: String, _ label: String, pressed: Bool) -> Bool {
        var words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if pressed, let space = words.firstIndex(of: " ") {
            words = String(words[words.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        for filler in ["the ", "on ", "on the "] where words.hasPrefix(filler) {
            words = String(words.dropFirst(filler.count))
        }
        return words == label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
