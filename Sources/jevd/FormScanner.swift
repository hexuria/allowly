import Foundation
import JevCore
import JevDecide

/// Turns the fields on screen into something the phone can show as a form.
///
/// The finding itself now belongs to Cua Driver — see `CuaBackend.formFields`.
/// What is left here is the part that is genuinely ours: giving a name to the
/// fields a form could not be bothered to label.
///
/// Dictating a password is not an option — it would be spoken aloud, sent to a
/// transcription service and written to a log. Typing it blind on the phone is
/// barely better, because you cannot see which box it is going into. So the
/// Mac reads the form's shape out of the accessibility tree, the phone shows
/// it as a real form, and the values go straight into the named fields.
enum FormScanner {

    struct Field: Codable, Sendable {
        /// What the phone shows you. May be a name Jev invented for a field
        /// the form left unlabelled.
        let label: String
        let secret: Bool
        /// The accessibility role, for the phone's keyboard hints.
        let kind: String
        /// What the Mac actually calls it — the label the accessibility tree
        /// reports, before any renaming.
        ///
        /// Without this, naming an unlabelled field broke the very thing the
        /// naming exists for: the phone sent back "Card Number", the Mac
        /// looked for a control called "Card Number", the real label was
        /// still "Field 3", and the fill failed with "Nothing called Card
        /// Number" — on exactly the forms the feature was written to rescue.
        let realLabel: String

        init(label: String, secret: Bool, kind: String, realLabel: String? = nil) {
            self.label = label
            self.secret = secret
            self.kind = kind
            self.realLabel = realLabel ?? label
        }
    }


    /// Name the fields a form left unlabelled.
    ///
    /// A hand-rolled web form often exposes nothing but "Field 1" and
    /// "Field 2", which is useless on the phone. Jev can read the page's
    /// visible text and say which is which — a closed choice over field
    /// kinds, which is what it is good at. Only called when something is
    /// genuinely unnamed, so a well-built form costs nothing.
    /// Names that mean "do not let this be dictated", whatever the form
    /// chose to call the box.
    static func sensitive(_ choice: String) -> Bool {
        ["password", "card number", "code", "pin", "security code"].contains(choice.lowercased())
    }

    /// - Parameter nearby: visible labels from Cua Driver, used as context.
    static func nameUnlabelled(_ fields: [Field], nearby: [String], apiKey: String?) async -> [Field] {
        // Both spellings jev invents for an unlabelled box. Filtering on
        // "Field " alone meant a box that had to fall back to the other
        // name was quietly excluded from the naming pass.
        let unnamed = fields.enumerated().filter {
            $0.element.label.hasPrefix("Field ") || $0.element.label.hasPrefix("Unnamed box ")
        }
        guard !unnamed.isEmpty, let apiKey else { return fields }

        let kinds = ["email", "username", "password", "search", "full name", "phone",
                     "address", "card number", "code", "message", "other"]
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
                         // A field Jev names "card number", "code" or "pin"
                         // is as secret as one it names "password".
                         secret: field.secret || Self.sensitive(answer.choice),
                         kind: field.kind,
                         // Keep the ADDRESS, not the caption. Renaming
                         // "Field 3" to "Card Number" must not change where
                         // the value goes.
                         realLabel: field.realLabel)
        }
    }
}
