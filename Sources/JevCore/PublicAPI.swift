import Foundation

// MARK: - Public API

// Export all domain types for use by other targets.
// This file serves as the public interface for JevCore.

// MARK: Domain Types
// ApprovalKind, RiskLevel, DecisionValue, DecisionSource, ExecutionStatus
// ApprovalOption, ApplicationInfo, ApprovalRequest
// Decision, ExecutionResult, Command, Nonce, DeviceIdentity
// (all defined in Types.swift)

// MARK: Policy
// Policy type and strictDefault() factory
// (defined in Policy.swift)

// MARK: Approval Store
// ApprovalStore actor for managing pending requests
// (defined in ApprovalStore.swift)

// MARK: Self-Tests
// Public function to run sanity checks:
// let failures = SelfTest.run()

extension SelfTest {
    /// Run all self-tests and return failure descriptions.
    /// Usage: let failures = SelfTest.run()
    /// An empty array means all tests passed.
    public static func selfTest() -> [String] {
        return SelfTest.run()
    }
}
