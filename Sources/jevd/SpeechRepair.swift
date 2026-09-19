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
///   * a reading that parses when the top one does not → take it, no call;
///   * readings that mean different things → ask Jev which you said.
enum SpeechRepair {

    static func choose(_ heard: Heard, apiKey: String?) async -> String {
        let candidates = [heard.best] + heard.alternatives
        guard candidates.count > 1 else { return heard.best }

        // What each reading would actually do. Unparseable ones are kept as
        // candidates — Jev may still recognise one as the real sentence.
        let parsed = candidates.map { (text: $0, action: VoiceCommand.parse($0)?.description) }
        let distinct = Set(parsed.compactMap(\.action))

        // Every reading that means something means the same thing: nothing to
        // resolve, and the wording does not matter.
        if distinct.count <= 1 {
            if parsed.first?.action != nil { return heard.best }
            // The top reading is not a command but a lower one is: the
            // recogniser simply ranked them wrong.
            if let rescued = parsed.first(where: { $0.action != nil }) {
                JevLog.write("[jev] heard “\(heard.best)”, using “\(rescued.text)” instead")
                return rescued.text
            }
            return heard.best
        }

        // Genuine ambiguity. Only now is a model call worth its latency.
        guard let apiKey else { return heard.best }

        let labels = parsed.map(\.text)
        let described = parsed
            .map { "\($0.text) → \($0.action ?? "not a known command")" }
            .joined(separator: "; ")

        let result = await JevAPI.ask(
            state: [
                "readings": labels,
                "what_each_would_do": described,
                "frontmost_app": Phrasebook.context().appName,
            ],
            questions: [
                "said": .choice(
                    instructions: "Speech recognition produced these competing readings of one short spoken command to a Mac. Which one did the person actually say? Prefer the reading that is a sensible thing to ask a computer to do right now.",
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
            JevLog.write("[jev] heard “\(heard.best)”, Jev says “\(choice.choice)” "
                + "(\(String(format: "%.2f", choice.confidence)))")
        }
        return choice.choice
    }
}
