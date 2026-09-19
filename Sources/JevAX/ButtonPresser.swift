import Foundation
import ApplicationServices
import JevCore

/// Result of attempting to press a button in a dialog.
public enum ButtonPressResult: Sendable {
    case success(message: String)
    case notFound(message: String)
    case forbidden(message: String)
    case accessibilityError(message: String)
}

/// ButtonPresser handles pressing buttons in dialogs and sheets.
/// It respects the Policy and refuses to press dangerous buttons.
public struct ButtonPresser {
    private let policy: Policy
    private let serialiser: DialogSerialiser

    public init(policy: Policy) {
        self.policy = policy
        self.serialiser = DialogSerialiser()
    }

    /// Attempt to press a button by label in the given dialog element.
    /// Checks policy constraints before pressing.
    public func pressButton(in dialogElement: AXUIElement, withLabel label: String) -> ButtonPressResult {
        // Check if the button label is forbidden by policy
        if policy.dangerousButtonLabels.contains(where: { dangerous in
            label.lowercased().contains(dangerous.lowercased())
        }) {
            return .forbidden(message: "Button label '\(label)' is forbidden by policy")
        }

        // Find the button element
        guard let button = serialiser.findButton(in: dialogElement, withTitle: label) else {
            return .notFound(message: "Button with label '\(label)' not found in dialog")
        }

        // Attempt to press it
        return pressElement(button, label: label)
    }

    /// Attempt to press a button by option ID.
    /// This translates the option ID to a button label and presses it.
    public func pressButtonByOptionId(in dialogElement: AXUIElement, optionId: String) -> ButtonPressResult {
        // Find the button with the matching title
        let buttons = serialiser.extractButtons(element: dialogElement)

        // Simple heuristic: match option ID against button labels
        // In a real implementation, this would map option IDs to the ApprovalRequest's options
        guard let matchingButton = buttons.first(where: { button in
            button.lowercased().contains(optionId.lowercased())
        }) else {
            return .notFound(message: "No button found matching option ID '\(optionId)'")
        }

        return pressButton(in: dialogElement, withLabel: matchingButton)
    }

    /// Press a button element directly.
    private func pressElement(_ button: AXUIElement, label: String) -> ButtonPressResult {
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)

        switch error {
        case .success:
            return .success(message: "Pressed button '\(label)'")
        case .failure:
            return .accessibilityError(message: "General accessibility failure")
        case .apiDisabled:
            return .accessibilityError(message: "Accessibility API is disabled")
        case .noValue:
            return .accessibilityError(message: "Button has no press action available")
        case .attributeUnsupported:
            return .accessibilityError(message: "Press action not supported on this button")
        case .actionUnsupported:
            return .accessibilityError(message: "Button does not support the press action")
        case .invalidUIElement:
            return .accessibilityError(message: "Invalid UI element")
        case .invalidUIElementObserver:
            return .accessibilityError(message: "Invalid UI element observer")
        case .notImplemented:
            return .accessibilityError(message: "Press action not implemented")
        case .notificationUnsupported:
            return .accessibilityError(message: "Notification not supported")
        case .notificationAlreadyRegistered:
            return .accessibilityError(message: "Notification already registered")
        case .notificationNotRegistered:
            return .accessibilityError(message: "Notification not registered")
        case .illegalArgument:
            return .accessibilityError(message: "Invalid argument to press action")
        case .cannotComplete:
            return .accessibilityError(message: "Cannot complete press action")
        case .parameterizedAttributeUnsupported:
            return .accessibilityError(message: "Parameterized attribute not supported")
        case .notEnoughPrecision:
            return .accessibilityError(message: "Not enough precision")
        @unknown default:
            return .accessibilityError(message: "Unknown accessibility error")
        }
    }
}
