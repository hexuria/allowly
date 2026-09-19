import Foundation

public struct SelfTest {
    /// Run self-contained sanity checks on the domain model.
    /// Returns an array of failure descriptions (empty if all pass).
    public static func run() -> [String] {
        var failures: [String] = []

        failures.append(contentsOf: testStrictDefaultPolicyEscalatesUnknownApp())
        failures.append(contentsOf: testDangerousButtonLabelNotAutoPressed())
        failures.append(contentsOf: testReplayGuardRejectsDuplicate())
        failures.append(contentsOf: testRiskLevelOrdering())
        failures.append(contentsOf: testNonceValidation())
        failures.append(contentsOf: testPolicyCommandPrefix())

        return failures
    }

    /// An unknown app must reach the human, not be answered or discarded.
    private static func testStrictDefaultPolicyEscalatesUnknownApp() -> [String] {
        var failures: [String] = []
        let policy = Policy.strictDefault()

        let unknownApp = ApplicationInfo(name: "Unknown App", bundleIdentifier: "com.unknown.app")
        let request = ApprovalRequest(
            id: "test-1",
            kind: .appDialog,
            title: "Test",
            bodyText: "Test",
            options: [ApprovalOption(id: "ok", label: "OK", riskLevel: .low)],
            originatingApp: unknownApp,
            timestamp: Date()
        )

        let (decision, _) = policy.evaluate(request: request)
        if case .escalateToHuman = decision {
            // Expected: never auto-pressed, never silently dropped.
        } else {
            failures.append("Strict default policy should escalate an unknown app, got \(decision)")
        }

        return failures
    }

    private static func testDangerousButtonLabelNotAutoPressed() -> [String] {
        var failures: [String] = []
        let policy = Policy.strictDefault()

        let allowedApp = ApplicationInfo(name: "Allowed App", bundleIdentifier: "com.allowed.app")
        var allowedPolicy = Policy.strictDefault()
        allowedPolicy = Policy(
            allowedBundleIds: ["com.allowed.app"],
            allowedCommandPrefixes: [],
            dangerousButtonLabels: policy.dangerousButtonLabels,
            maxAutoApprovableRiskLevel: .low
        )

        let request = ApprovalRequest(
            id: "test-2",
            kind: .appDialog,
            title: "Test",
            bodyText: "Test",
            options: [
                ApprovalOption(id: "ok", label: "OK", riskLevel: .low),
                ApprovalOption(id: "delete", label: "Delete All", riskLevel: .low)
            ],
            originatingApp: allowedApp,
            timestamp: Date()
        )

        let (decision, _) = allowedPolicy.evaluate(request: request)
        if case .escalateToHuman = decision {
            // Expected
        } else {
            failures.append("Policy should escalate requests with dangerous button labels, got \(decision)")
        }

        return failures
    }

    private static func testReplayGuardRejectsDuplicate() -> [String] {
        var failures: [String] = []

        let now = Date()
        let nonce1 = Nonce(id: "test-nonce", timestamp: now)
        let nonce2 = Nonce(id: "test-nonce", timestamp: now)

        if !nonce1.isValid(against: nonce2) {
            // Expected: duplicate nonce should be rejected
        } else {
            failures.append("Replay guard should reject duplicate nonce")
        }

        return failures
    }

    private static func testRiskLevelOrdering() -> [String] {
        var failures: [String] = []

        if !(RiskLevel.low < RiskLevel.medium) {
            failures.append("RiskLevel: low should be less than medium")
        }
        if !(RiskLevel.medium < RiskLevel.high) {
            failures.append("RiskLevel: medium should be less than high")
        }
        if RiskLevel.high < RiskLevel.low {
            failures.append("RiskLevel: high should not be less than low")
        }

        return failures
    }

    private static func testNonceValidation() -> [String] {
        var failures: [String] = []

        let now = Date()

        // Test 1: Recent nonce should be valid against nil
        let recentNonce = Nonce(id: "test-nonce", timestamp: now)
        if !recentNonce.isValid(against: nil) {
            failures.append("Recent nonce should be valid when there is no previous nonce")
        }

        // Test 2: Old nonce (outside replay window) should be invalid
        let oldDate = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 60) // 60 seconds ago
        let oldNonce = Nonce(id: "old-nonce", timestamp: oldDate)
        if oldNonce.isValid(against: nil) {
            failures.append("Nonce older than replay window should be invalid")
        }

        // Test 3: Recent nonce with different id should be valid against previous nonce
        let previousNonce = Nonce(id: "different-nonce", timestamp: now)
        let newNonce = Nonce(id: "another-nonce", timestamp: now)
        if !newNonce.isValid(against: previousNonce) {
            failures.append("Different nonce should be valid against previous nonce")
        }

        return failures
    }

    private static func testPolicyCommandPrefix() -> [String] {
        var failures: [String] = []

        let policy = Policy(
            allowedBundleIds: [],
            allowedCommandPrefixes: ["/bin/echo"],
            dangerousButtonLabels: [],
            maxAutoApprovableRiskLevel: .high
        )

        if policy.allowedCommandPrefixes.contains("/bin/echo") {
            // Expected
        } else {
            failures.append("Policy should preserve allowed command prefixes")
        }

        return failures
    }
}
