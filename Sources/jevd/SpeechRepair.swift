import Foundation
import JevCore
import JevDecide

/// Picks which of the recogniser's readings you actually said.
///
/// Speech recognition hands back several candidate transcriptions. Keeping
/// only the top one is what makes a voice interface feel broken: "quit Notes"
/// comes back as "open Notes", both are grammatical, both parse, and the Mac
/// confidently does the opposite of what you asked.
///
/// Jev is exactly the right tool here — a closed choice between a handful of
/// things that were really heard — but it is only worth a call when the
/// readings genuinely disagree. So:
///
///   * one reading, or all readings meaning the same thing → free, no call;
///   * a reading that names something visible on screen → take it, no call;
///   * a reading that parses when the top one does not → take it, no call;
///   * readings that mean different things → ask Jev which you said.
enum SpeechRepair {

    /// Verbs that mean "press the thing I can see", as opposed to any of the
    /// global shortcuts. Kept here rather than in Phrasebook because this is
    /// about recognising the *shape* of a sentence, not executing it.
    private static let pressVerbs = ["click", "press", "tap", "push", "hit", "choose", "select"]

    /// - Parameter controls: labels of what is on screen right now. Without
    ///   these, "click skip" is indistinguishable from noise and the literal
    ///   parser calls it "not a known command" — which is how a spoken
    ///   "click skip" became the media key for *next track* while a Skip
    ///   button sat on screen. Nothing here can name an on-screen control,
    ///   so nothing here could defend it.
    static func choose(_ heard: Heard, controls: [String] = [], apiKey: String?) async -> String {
        let candidates = [heard.best] + heard.alternatives
        guard candidates.count > 1 else { return heard.best }

        // A reading that names something you can actually see wins outright.
        //
        // The recogniser drops leading words far more often than it invents
        // them, so between "click skip" and "skip" the longer one is the
        // safer bet — and when the shorter one happens to collide with a
        // global shortcut, taking it does something entirely unrelated in a
        // different application. Free, local, and no model call.
        let onScreen = candidates.filter { names(aControlIn: controls, $0) }
        if let named = onScreen.first, onScreen.count == 1 || named != heard.best {
            if named != heard.best {
                // The chosen reading is safe to name: it matches a
                // control that is on screen. The raw one is not.
                JevLog.write("[jev] heard \(JevLog.shape(heard.best)), using “\(JevLog.safe(named))” — it names something on screen")
            }
            return named
        }

        // What each reading would actually do. Unparseable ones are kept as
        // candidates — Jev may still recognise one as the real sentence.
        //
        // The whole `Parsed`, not just its description: whether a reading is
        // safe to write down depends on the COMMAND it becomes, and throwing
        // that away here is why "create a note hunter2 is the wifi key" went
        // to the log in full. `JevLog.safe` keys on a ten-verb list, and
        // "create a note" is not on it — but the command it builds is a
        // `.typeText`, which `carriesFreeText` recognises instantly.
        let parsed = candidates.map { (text: $0, parsed: VoiceCommand.parse($0)) }
            .map { (text: $0.text, command: $0.parsed?.command, action: $0.parsed?.description) }
        let distinct = Set(parsed.compactMap(\.action))

        // Every reading that means something means the same thing: nothing to
        // resolve, and the wording does not matter.
        if distinct.count <= 1 {
            if parsed.first?.action != nil { return heard.best }
            // The top reading is not a command but a lower one is: the
            // recogniser simply ranked them wrong.
            if let rescued = parsed.first(where: { $0.action != nil }) {
                JevLog.write("[jev] heard \(JevLog.shape(heard.best)), using \(Self.loggable(rescued.text, rescued.command)) instead")
                return rescued.text
            }
            return heard.best
        }

        // Genuine ambiguity. Only now is a model call worth its latency.
        guard let apiKey else { return heard.best }

        let labels = parsed.map(\.text)
        let described = parsed
            .map { "\($0.text) → \(effect(of: $0.text, parsedAs: $0.action, controls: controls))" }
            .joined(separator: "; ")

        let result = await JevAPI.ask(
            state: [
                "readings": labels,
                "what_each_would_do": described,
                "frontmost_app": Phrasebook.context().appName,
                // Without this the model is choosing blind, and it reliably
                // picks whichever reading the literal parser recognised —
                // which is exactly the wrong bias when the real sentence is
                // about something on screen.
                "visible_on_screen": Array(controls.prefix(40)),
            ],
            questions: [
                "said": .choice(
                    instructions: "Speech recognition produced these competing readings of one short spoken command to a Mac. Which one did the person actually say? They are looking at a picture of this screen on their phone, so a reading that names something in visible_on_screen is usually the real one. Recognisers drop leading words more often than they invent them, so prefer the longer reading when one is the other plus a verb.",
                    labels: labels)
            ],
            apiKey: apiKey)

        guard case .success(let answers) = result,
              let choice = answers.choice("said"),
              choice.confidence >= 0.5,
              labels.contains(choice.choice) else {
            return heard.best
        }

        if choice.choice != heard.best {
            // The model can pick ANY candidate, including one nothing
            // parsed — so this reading has not necessarily been interpreted.
            JevLog.write("[jev] heard \(JevLog.shape(heard.best)), Jev says \(Self.loggable(choice.choice, VoiceCommand.parse(choice.choice)?.command)) "
                + "(\(String(format: "%.2f", choice.confidence)))")
        }
        return choice.choice
    }

    /// Does this reading ask for something that is on screen right now?
    private static func names(aControlIn controls: [String], _ reading: String) -> Bool {
        guard !controls.isEmpty else { return false }
        let text = reading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = pressVerbs.first(where: { text.hasPrefix($0 + " ") }) else { return false }
        let target = text.dropFirst(verb.count + 1)
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " button", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= 2 else { return false }
        return controls.contains { $0.lowercased() == target }
    }

    /// What a reading would do, in words — including the case the literal
    /// parser cannot see, which is pressing something on screen.
    private static func effect(of reading: String, parsedAs action: String?, controls: [String]) -> String {
        if names(aControlIn: controls, reading) {
            return "press the “\(reading.split(separator: " ").dropFirst().joined(separator: " "))” "
                + "control that is visible on screen"
        }
        return action ?? "not a known command"
    }

    /// A reading, written down only if the command it becomes carries no
    /// words the person supplied.
    ///
    /// The rule this file follows: log what jev understood, never what it
    /// merely heard. A reading that becomes `next tab` is a command and can
    /// be named; one that becomes "type this" is a value wearing a verb.
    static func loggable(_ text: String, _ command: Command?) -> String {
        guard command != nil, !CommandJournal.carriesFreeText(command) else {
            return JevLog.shape(text)
        }
        return "“\(JevLog.safe(text))”"
    }

}
