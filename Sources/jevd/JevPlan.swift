import Foundation
import JevCore
import JevDecide

/// Lets Jev build a sequence it was never taught.
///
/// Until now every multi-step action had to be written out by hand in the
/// Phrasebook, and Jev's only power was to pick one of them. So "close all
/// tabs" worked because someone had written it down, and anything nobody had
/// anticipated failed with "did not understand" — even when it was obviously
/// two or three things jev can already do, in order.
///
/// The trick to composing with a closed-choice classifier is that it can only
/// return labels, never free-form JSON. So the plan is asked for as an ordered
/// series of choices, and the choices are the Phrasebook's own canonical
/// phrases. Every step is therefore something that provably executes on this
/// machine: Jev picks the order, not the actions, and cannot invent a step
/// that does not exist.
enum JevPlan {

    struct Plan {
        let steps: [Command]
        let phrases: [String]
        let confidence: Double

        var description: String { "Plan: " + phrases.joined(separator: " → ") }
    }

    /// The most steps worth asking for. Past four the classifier is guessing,
    /// and a wrong four-step plan is already hard to undo.
    private static let maxSteps = 4

    static func compose(transcript: String, apiKey: String) async -> Plan? {
        let catalog = Phrasebook.catalog()
        guard !catalog.isEmpty else { return nil }
        let labels = catalog + [done]

        var questions: [String: JevAPI.Question] = [:]
        for index in 1...maxSteps {
            questions["step_\(index)"] = .choice(
                instructions: index == 1
                    ? "The user asked a Mac assistant to do something that is not a single known action. Build the shortest sequence of known actions that accomplishes it. What is step 1? Choose “\(done)” if no sequence of these actions can do it."
                    : "What is step \(index) of that sequence? Choose “\(done)” if the sequence is already complete after step \(index - 1).",
                labels: labels)
        }

        let result = await JevAPI.ask(
            state: [
                "request": transcript,
                "frontmost_app": Phrasebook.context().appName,
            ],
            questions: questions,
            apiKey: apiKey)

        guard case .success(let answers) = result else { return nil }

        var steps: [Command] = []
        var phrases: [String] = []
        var confidence = 1.0

        for index in 1...maxSteps {
            guard let answer = answers.choice("step_\(index)") else { break }
            // "done" ends the plan. So does a step Jev is not sure about —
            // a shorter confident plan beats a longer speculative one.
            if answer.choice == done || answer.confidence < 0.4 { break }
            guard let parsed = Phrasebook.build(canonical: answer.choice) else { break }
            // A step that repeats the one before it is the classifier padding
            // out the sequence rather than adding anything.
            if phrases.last == answer.choice { break }
            steps.append(parsed.command)
            phrases.append(answer.choice)
            confidence = min(confidence, answer.confidence)
        }

        // One step is not a plan — that path is already covered by the single
        // capability choice, and re-answering it here would only add latency.
        guard steps.count >= 2 else { return nil }

        // A plan nobody is confident in is worse than admitting ignorance:
        // it puts a wrong sequence in front of you dressed up as an answer.
        guard confidence >= 0.5 else {
            JevLog.write("[jev] plan for “\(transcript)” discarded: "
                + "\(phrases.joined(separator: " → ")) only \(String(format: "%.2f", confidence))")
            return nil
        }

        JevLog.write("[jev] plan for “\(transcript)”: \(phrases.joined(separator: " → ")) "
            + "(\(String(format: "%.2f", confidence)))")
        return Plan(steps: steps, phrases: phrases, confidence: confidence)
    }

    private static let done = "nothing more"
}
