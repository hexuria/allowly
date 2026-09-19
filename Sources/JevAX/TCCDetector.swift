import Foundation
import ApplicationServices

/// TCCDetector identifies TCC (Transparency, Consent, and Control) consent sheets.
/// These sheets cannot be clicked via synthetic input and must be handed off to the human.
public struct TCCDetector {
    // Process names that generate TCC consent sheets
    private static let tccProcessNames = [
        "tccd",
        "SecurityAgent",
        "UserNotificationCenter",
        "Finder"
    ]

    // Common TCC consent prompt patterns in sheet text
    private static let tccPromptPatterns = [
        "wants to access",
        "ask you to approve",
        "requesting access",
        "is requesting access",
        "You have not yet chosen",
        "is asking to access"
    ]

    /// Detect if an AXUIElement is a TCC consent sheet.
    /// This checks both the owning process name and the dialog text content.
    /// TCC sheets cannot be driven by synthetic input and must be marked handoffOnly.
    public static func isTCCDialog(element: AXUIElement?, processName: String?) -> Bool {
        // Check by process name first
        if let processName = processName {
            if isTCCProcess(processName) {
                return true
            }
        }

        // Check the element's text content for TCC patterns
        if let element = element {
            if hasCharacteristicTCCText(element) {
                return true
            }
        }

        return false
    }

    /// Check if a process name is known to generate TCC dialogs.
    private static func isTCCProcess(_ processName: String) -> Bool {
        return tccProcessNames.contains { name in
            processName.lowercased().contains(name.lowercased())
        }
    }

    /// Scan an accessibility element's text for characteristic TCC patterns.
    /// This recursively walks the element tree looking for matching text.
    private static func hasCharacteristicTCCText(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) -> Bool {
        guard depth < maxDepth else { return false }

        // Check this element's description/text content
        var description: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description) == .success,
           let desc = description as? String {
            if matchesTCCPattern(desc) {
                return true
            }
        }

        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let val = value as? String {
            if matchesTCCPattern(val) {
                return true
            }
        }

        // Check children recursively
        var children: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray.prefix(20) { // Limit number of children checked
                if hasCharacteristicTCCText(child, depth: depth + 1, maxDepth: maxDepth) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if text matches any TCC pattern.
    private static func matchesTCCPattern(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return tccPromptPatterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }
    }
}
