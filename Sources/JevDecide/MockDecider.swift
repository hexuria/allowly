import Foundation
import JevCore

/// MockDecider is the DEFAULT when no TypeSafe API key is present.
/// It is fully deterministic, requires no network, and is used for demonstrations
/// and development. It only auto-allows what the strict Policy already permits,
/// and escalates everything else to the human.
public actor MockDecider: Decider {
    private let policyDecider: PolicyDecider

    public init() {
        // Use strict default policy: deny by default, no allowlisted apps.
        let strictPolicy = Policy.strictDefault()
        self.policyDecider = PolicyDecider(policy: strictPolicy)
    }

    /// Make a mock decision: auto-allow only what strict policy allows, else ask human.
    /// No network, no API calls, fully deterministic.
    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        // Delegate to PolicyDecider with strict policy.
        // The PolicyDecider will return:
        // - .allow with confidence 1.0 if policy auto-allows
        // - .deny with confidence 1.0 if policy auto-denies
        // - .askHuman with confidence 0.0 if policy escalates
        return await policyDecider.decide(request: request, dialogText: dialogText)
    }
}
