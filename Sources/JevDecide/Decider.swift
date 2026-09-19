import Foundation
import JevCore

/// Protocol for decision engines that determine whether to auto-approve, auto-deny,
/// or escalate approval requests to a human.
public protocol Decider: Sendable {
    /// Make a decision about an approval request.
    /// - Parameters:
    ///   - request: The approval request to evaluate.
    ///   - dialogText: The serialized accessibility tree or dialog text.
    /// - Returns: A Decision indicating the action to take.
    func decide(request: ApprovalRequest, dialogText: String) async -> Decision
}
