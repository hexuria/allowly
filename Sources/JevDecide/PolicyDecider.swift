import Foundation
import JevCore

/// PolicyDecider applies JevCore's Policy to make synchronous auto-allow/deny decisions.
/// This runs FIRST and can short-circuit before any network call.
/// Deny-by-default: if policy cannot auto-allow, it escalates to the human.
public actor PolicyDecider: Decider {
    private let policy: Policy

    public init(policy: Policy) {
        self.policy = policy
    }

    /// Apply policy evaluation. Returns auto-allow, auto-deny, or escalate to human.
    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        let (policyDecision, reason) = policy.evaluate(request: request)

        switch policyDecision {
        case .autoAllow:
            return Decision(
                value: .allow,
                chosenOptionId: nil,
                confidence: 1.0,
                reason: reason,
                source: .policy
            )

        case .autoDeny:
            return Decision(
                value: .deny,
                chosenOptionId: nil,
                confidence: 1.0,
                reason: reason,
                source: .policy
            )

        case .escalateToHuman:
            return Decision(
                value: .askHuman,
                chosenOptionId: nil,
                confidence: 0.0,
                reason: reason,
                source: .policy
            )
        }
    }
}
