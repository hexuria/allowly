import Foundation

public enum PolicyDecision: Sendable {
    case autoAllow
    case autoDeny
    case escalateToHuman
}

public struct Policy: Sendable {
    // Allowed app bundle identifiers
    public let allowedBundleIds: Set<String>

    // Allowed shell command prefixes (exact match)
    public let allowedCommandPrefixes: Set<String>

    // Button labels that should never be auto-pressed (dangerous labels)
    public let dangerousButtonLabels: Set<String>

    // Maximum risk level that can be auto-approved
    public let maxAutoApprovableRiskLevel: RiskLevel

    public init(
        allowedBundleIds: Set<String> = [],
        allowedCommandPrefixes: Set<String> = [],
        dangerousButtonLabels: Set<String> = [],
        maxAutoApprovableRiskLevel: RiskLevel = .low
    ) {
        self.allowedBundleIds = allowedBundleIds
        self.allowedCommandPrefixes = allowedCommandPrefixes
        self.dangerousButtonLabels = dangerousButtonLabels
        self.maxAutoApprovableRiskLevel = maxAutoApprovableRiskLevel
    }

    /// Evaluate an approval request against this policy.
    /// Returns the policy decision and a reason string.
    public func evaluate(request: ApprovalRequest) -> (decision: PolicyDecision, reason: String) {
        // TCC sheets must always be handed off to the human.
        if request.handoffOnly {
            return (.escalateToHuman, "TCC consent sheet requires human interaction")
        }

        // Not in the allowlist means "do not answer this on their behalf" —
        // it does not mean "throw it away". Auto-denying here made the product
        // useless for its whole reason to exist: a dialog from any app you had
        // not pre-approved was silently dropped and never reached your phone,
        // which is exactly the dialog you are away from the laptop for.
        //
        // A real refusal is an explicit "never" the person set, and that is
        // held per app outside this static policy.
        guard allowedBundleIds.contains(request.originatingApp.bundleIdentifier) else {
            return (.escalateToHuman, "\(request.originatingApp.name) has not been allowed yet")
        }

        // Check for dangerous button labels in the available options.
        for option in request.options {
            if isDangerousLabel(option.label) {
                return (.escalateToHuman, "One or more options contain dangerous labels")
            }
        }

        // Reject any request with options that exceed the max auto-approvable risk level.
        for option in request.options {
            if option.riskLevel > maxAutoApprovableRiskLevel {
                return (.escalateToHuman, "One or more options exceed the maximum auto-approvable risk level")
            }
        }

        // If all checks pass, auto-allow for this app.
        return (.autoAllow, "All options and app are within policy")
    }

    /// Check if a label contains dangerous keywords that should never be auto-pressed.
    private func isDangerousLabel(_ label: String) -> Bool {
        let lowercased = label.lowercased()

        for dangerous in dangerousButtonLabels {
            if lowercased.contains(dangerous.lowercased()) {
                return true
            }
        }

        return false
    }

    /// Create the strict default policy: deny by default, dangerous labels are blocked.
    public static func strictDefault() -> Policy {
        Policy(
            allowedBundleIds: [],
            allowedCommandPrefixes: [],
            dangerousButtonLabels: [
                "delete",
                "erase",
                "send",
                "purchase",
                "trust",
                "always allow",
                "allow all",
                "grant",
                "confirm delete"
            ],
            maxAutoApprovableRiskLevel: .low
        )
    }
}
