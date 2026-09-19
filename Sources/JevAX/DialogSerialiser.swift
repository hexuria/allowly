import Foundation
import ApplicationServices

/// DialogSerialiser converts an AXUIElement dialog into compact, readable text.
/// It walks the element tree, extracting roles, titles, values, and pressable buttons.
/// Output is designed to be information-dense and stable for analysis by Jev.
public struct DialogSerialiser {
    private let maxDepth: Int = 8
    private let maxElementsPerLevel: Int = 50
    private let maxTotalElements: Int = 200

    // Role constants as strings (these cannot be imported directly)
    private static let kAXButtonRole = "AXButton"

    public init() {}

    /// Serialize an AXUIElement dialog to text.
    /// Returns a compact text representation with role, title, body, and buttons.
    public func serialize(element: AXUIElement) -> String {
        var elementCount: Int = 0
        var output = ""

        // Start with the window/dialog itself
        if let role = getAttribute(element, kAXRoleAttribute as CFString) as? String {
            output += "[\(role)]"
        }

        if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String {
            output += " \(title)"
        }

        output += "\n"

        // Walk the tree and collect text and buttons
        let content = walkElement(element, depth: 0, elementCount: &elementCount)
        output += content

        return output
    }

    /// Recursively walk an element tree, extracting text and button information.
    private func walkElement(_ element: AXUIElement, depth: Int, elementCount: inout Int) -> String {
        guard depth < maxDepth else { return "" }
        guard elementCount < maxTotalElements else { return "" }

        var output = ""
        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String ?? "unknown"

        // Extract meaningful text from this element
        if let value = getAttribute(element, kAXValueAttribute as CFString) as? String, !value.isEmpty {
            output += value + "\n"
        }

        if let description = getAttribute(element, kAXDescriptionAttribute as CFString) as? String, !description.isEmpty {
            output += description + "\n"
        }

        // Special handling for buttons
        if role == Self.kAXButtonRole {
            if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String {
                output += "BUTTON: \(title)\n"
            }
        }

        // Walk children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                output += walkElement(child, depth: depth + 1, elementCount: &elementCount)
            }
        }

        return output
    }

    /// Safely get an attribute from an AXUIElement.
    private func getAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }

    /// Extract all pressable buttons from a dialog element.
    /// Returns a list of button labels that can be pressed.
    public func extractButtons(element: AXUIElement) -> [String] {
        var elementCount: Int = 0
        var buttons: [String] = []
        findButtons(element, depth: 0, elementCount: &elementCount, into: &buttons)
        return buttons
    }

    /// Recursively find all buttons in an element tree.
    private func findButtons(_ element: AXUIElement, depth: Int, elementCount: inout Int, into buttons: inout [String]) {
        guard depth < maxDepth else { return }
        guard elementCount < maxTotalElements else { return }

        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String

        // Collect buttons
        if role == Self.kAXButtonRole {
            if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String {
                buttons.append(title)
            }
        }

        // Walk children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                findButtons(child, depth: depth + 1, elementCount: &elementCount, into: &buttons)
            }
        }
    }

    /// Find a button element by title within a dialog.
    public func findButton(in element: AXUIElement, withTitle title: String) -> AXUIElement? {
        var elementCount: Int = 0
        return findButtonRecursive(element, title: title, depth: 0, elementCount: &elementCount)
    }

    private func findButtonRecursive(_ element: AXUIElement, title: String, depth: Int, elementCount: inout Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard elementCount < maxTotalElements else { return nil }

        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String

        // Check if this is a matching button
        if role == Self.kAXButtonRole {
            if let buttonTitle = getAttribute(element, kAXTitleAttribute as CFString) as? String {
                if buttonTitle.lowercased().contains(title.lowercased()) ||
                   title.lowercased().contains(buttonTitle.lowercased()) {
                    return element
                }
            }
        }

        // Search children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                if let found = findButtonRecursive(child, title: title, depth: depth + 1, elementCount: &elementCount) {
                    return found
                }
            }
        }

        return nil
    }
}
