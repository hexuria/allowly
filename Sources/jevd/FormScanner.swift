import Foundation
import AppKit
import ApplicationServices
import JevCore
import JevAX
import JevDecide

/// Finds the fields on screen so they can be filled from the phone.
///
/// Dictating a password is not an option — it would be spoken aloud, sent to a
/// transcription service and written to a log. Typing it blind on the phone is
/// barely better, because you cannot see which box it is going into. So the
/// Mac reads the form's shape out of the accessibility tree, the phone shows
/// it as a real form, and the values go straight into the named fields.
enum FormScanner {

    struct Field: Codable, Sendable {
        let label: String
        let secret: Bool
        /// The accessibility role, for the phone's keyboard hints.
        let kind: String
    }

    private static let fieldRoles = [
        "AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox",
    ]

    /// Every fillable field in the frontmost window, in reading order.
    static func frontmostFields(limit: Int = 12) -> [Field] {
        guard AccessibilityPermission.isTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return [] }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron expose nothing until asked.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetMessagingTimeout(axApp, 2.0)

        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              CFGetTypeID(windowValue!) == AXUIElementGetTypeID() else { return [] }

        var found: [(field: Field, frame: CGRect)] = []
        walk(windowValue as! AXUIElement, depth: 0, into: &found, limit: limit)

        // Reading order: down the page, then across.
        return found
            .sorted { lhs, rhs in
                abs(lhs.frame.minY - rhs.frame.minY) > 8
                    ? lhs.frame.minY < rhs.frame.minY
                    : lhs.frame.minX < rhs.frame.minX
            }
            .map(\.field)
    }

    private static func walk(_ element: AXUIElement, depth: Int,
                             into out: inout [(field: Field, frame: CGRect)], limit: Int) {
        guard depth < 16, out.count < limit else { return }

        let role = string(element, kAXRoleAttribute) ?? ""
        if fieldRoles.contains(role) {
            // A form field is usually empty, so its *value* is no help. The
            // placeholder is what a person reads, which is why it comes first.
            let label = string(element, kAXPlaceholderValueAttribute)
                ?? string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute)
                ?? labelFromSibling(of: element)
                ?? (role == "AXSecureTextField" ? "Password" : "Field \(out.count + 1)")

            // A secure field is definitive; a plain field named "password" is
            // a site that built its own, and the value is just as sensitive.
            let secret = role == "AXSecureTextField"
                || label.lowercased().contains("password")
                || label.lowercased().contains("passcode")

            out.append((Field(label: label, secret: secret, kind: role), frame(of: element)))
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, into: &out, limit: limit) }
    }

    /// Many forms put the label in a separate static text next to the box.
    /// AXTitleUIElement points at it when the app bothered to link them.
    private static func labelFromSibling(of element: AXUIElement) -> String? {
        var linked: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &linked) == .success,
              CFGetTypeID(linked!) == AXUIElementGetTypeID() else { return nil }
        let label = linked as! AXUIElement
        return string(label, kAXValueAttribute) ?? string(label, kAXTitleAttribute)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return .zero }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Name the fields a form left unlabelled.
    ///
    /// A hand-rolled web form often exposes nothing but "Field 1" and
    /// "Field 2", which is useless on the phone. Jev can read the page's
    /// visible text and say which is which — a closed choice over field
    /// kinds, which is what it is good at. Only called when something is
    /// genuinely unnamed, so a well-built form costs nothing.
    static func nameUnlabelled(_ fields: [Field], apiKey: String?) async -> [Field] {
        let unnamed = fields.enumerated().filter { $0.element.label.hasPrefix("Field ") }
        guard !unnamed.isEmpty, let apiKey else { return fields }

        let kinds = ["email", "username", "password", "search", "full name", "phone",
                     "address", "card number", "code", "message", "other"]
        let nearby = JevIntent.frontmostControls(limit: 40).map(\.label)

        var questions: [String: JevAPI.Question] = [:]
        for (index, _) in unnamed {
            questions["field_\(index)"] = .choice(
                instructions: "A form on screen has \(fields.count) fields, in order: "
                    + fields.map(\.label).joined(separator: ", ")
                    + ". What is field number \(index + 1) for?",
                labels: kinds)
        }

        let result = await JevAPI.ask(
            state: ["visible_text": nearby, "frontmost_app": Phrasebook.context().appName],
            questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else { return fields }

        return fields.enumerated().map { index, field in
            guard let answer = answers.choice("field_\(index)"),
                  answer.confidence >= 0.5, answer.choice != "other" else { return field }
            return Field(label: answer.choice.capitalized,
                         secret: field.secret || answer.choice == "password",
                         kind: field.kind)
        }
    }
}
