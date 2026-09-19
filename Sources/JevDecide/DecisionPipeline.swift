import Foundation
import JevCore

/// Chains the decision engines:
///   1. PolicyDecider — local, synchronous, can short-circuit to allow or deny.
///   2. A remote decider (Jev) for the genuinely ambiguous cases, under a hard timeout.
///   3. Fall back to asking the human.
///
/// Policy always runs first, so nothing the allowlist already refuses is ever sent
/// to a model, and no model answer can widen what policy permits.
public actor DecisionPipeline: Decider {
    private let policyDecider: PolicyDecider
    private let remote: any Decider
    private let networkTimeout: Duration

    /// Whether this pipeline will actually reach the network. False when running on
    /// MockDecider, which is what happens with no API key configured.
    public let usesRemoteDecider: Bool

    public init(
        policyDecider: PolicyDecider,
        remote: any Decider,
        usesRemoteDecider: Bool,
        networkTimeout: Duration = .milliseconds(1500)
    ) {
        self.policyDecider = policyDecider
        self.remote = remote
        self.usesRemoteDecider = usesRemoteDecider
        self.networkTimeout = networkTimeout
    }

    /// Build the pipeline for the running environment.
    ///
    /// With no TYPESAFE_API_KEY present this selects MockDecider, so jev is fully
    /// usable with no credentials: policy auto-handles what it can and everything
    /// else goes to the phone.
    public static func standard(
        policy: Policy = .strictDefault(),
        apiKey: String? = nil
    ) -> DecisionPipeline {
        // Must go through JevAPI.loadAPIKey, which checks the environment AND
        // the key file. Reading only the environment meant the key was never
        // found when the app is launched normally — `open` does not inherit a
        // shell — so auto mode reported "no API key" with the key sitting on
        // disk the whole time.
        let key = apiKey ?? JevAPI.loadAPIKey()
        let hasKey = !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return DecisionPipeline(
            policyDecider: PolicyDecider(policy: policy),
            remote: hasKey ? JevDecider(apiKey: key) : MockDecider(),
            usesRemoteDecider: hasKey
        )
    }

    /// Ask the model directly, skipping the local policy gate.
    ///
    /// The normal pipeline runs deny-by-default policy first, which is right
    /// for dialogs but wrong for an explicit "let jev decide" mode: policy
    /// would refuse every unlisted app before the model ever saw the request,
    /// making auto a synonym for never.
    public func askModel(request: ApprovalRequest, dialogText: String) async -> Decision {
        guard usesRemoteDecider else {
            return Decision(
                value: .askHuman,
                chosenOptionId: nil,
                confidence: 0,
                reason: "Auto needs a Jev API key (TYPESAFE_API_KEY); asking you instead.",
                source: .policy
            )
        }
        let remote = self.remote
        return await withTimeout(networkTimeout) {
            await remote.decide(request: request, dialogText: dialogText)
        }
    }

    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        let policyDecision = await policyDecider.decide(request: request, dialogText: dialogText)

        switch policyDecision.value {
        case .allow, .deny:
            return policyDecision
        case .askHuman:
            break
        }

        let remote = self.remote
        return await withTimeout(networkTimeout) {
            await remote.decide(request: request, dialogText: dialogText)
        }
    }

    /// Race the work against a sleep and take whichever finishes first.
    ///
    /// The previous shape armed a canceller and then awaited the work
    /// unconditionally, which is not a timeout: an operation that ignores
    /// cancellation blocks forever. A real race bounds the wait regardless.
    private func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> Decision
    ) async -> Decision {
        let timedOut = Decision(
            value: .askHuman,
            chosenOptionId: nil,
            confidence: 0,
            reason: "Decider did not answer within \(timeout); escalating to human.",
            source: .policy
        )

        return await withTaskGroup(of: Decision?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? timedOut
        }
    }
}
