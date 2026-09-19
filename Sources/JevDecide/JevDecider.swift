import Foundation
import JevCore

/// Asks Jev whether a request should run.
///
/// Rewritten to use JevAPI, which is verified against the real service. The
/// previous version posted to api.typesafe.dev/v1/decide with an X-API-Key
/// header — a wholly invented contract that had never once succeeded, so every
/// auto decision failed its network call and silently fell back to asking the
/// human. Auto mode was indistinguishable from ask mode.
public actor JevDecider: Decider {
    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? JevAPI.loadAPIKey()
    }

    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        guard let apiKey, !apiKey.isEmpty else {
            return escalate("No Jev API key configured")
        }

        // Closed choices only: the options that genuinely exist on this
        // request, plus an explicit way to decline and to defer.
        var labels = request.options.map(\.label)
        labels.append("ask the human")
        if !labels.contains(where: { $0.lowercased() == "deny" }) {
            labels.append("deny")
        }

        let state: [String: Any] = [
            "request": request.title,
            "detail": dialogText,
            "application": request.originatingApp.name,
            "bundle_id": request.originatingApp.bundleIdentifier,
            "kind": request.kind.rawValue,
        ]

        let questions: [String: JevAPI.Question] = [
            "action": .choice(
                instructions: "A Mac assistant is deciding what to do about this request on the user's behalf. Which option should it take? Choose 'ask the human' if this deserves a person's judgement.",
                labels: labels
            ),
            "safe": .noul(
                instructions: "Is carrying this out immediately, with no human confirmation, safe and clearly what the user wants?"
            ),
        ]

        let result = await JevAPI.ask(state: state, questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else {
            if case .failure(let error) = result {
                return escalate("Jev unavailable: \(error)")
            }
            return escalate("Jev returned nothing")
        }

        guard let action = answers.choice("action") else {
            return escalate("Jev named no action")
        }
        let safety = answers.noul("safe") ?? 0

        if action.choice.lowercased() == "ask the human" {
            return escalate("Jev deferred to you")
        }
        if action.choice.lowercased() == "deny" {
            return Decision(value: .deny, chosenOptionId: nil, confidence: action.confidence,
                            reason: "Jev declined it", source: .jev)
        }

        // Only act unprompted when Jev is both confident and calls it safe.
        // Either doubt sends it to the human; that asymmetry is deliberate.
        guard action.confidence >= 0.6, safety >= 0.5 else {
            return escalate(String(format: "Jev was unsure (%.0f%% confident, %.0f%% safe)",
                                   action.confidence * 100, safety * 100))
        }

        let chosen = request.options.first { $0.label == action.choice }
        return Decision(
            value: .allow,
            chosenOptionId: chosen?.id,
            confidence: action.confidence,
            reason: "Jev chose “\(action.choice)”",
            source: .jev
        )
    }

    private func escalate(_ reason: String) -> Decision {
        Decision(value: .askHuman, chosenOptionId: nil, confidence: 0, reason: reason, source: .jev)
    }
}
