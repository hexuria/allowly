import Foundation

/// The details you would otherwise have to say out loud.
///
/// A tax number spoken into a phone goes through speech recognition, lands in
/// a transcript, and — if nothing local understood the sentence — reaches a
/// model. jev already refuses to let passwords take that path; a TIN, an SSS
/// number or a card is no different, and until now there was nowhere else for
/// them to go.
///
/// So they are entered once, typed, at the Mac, and kept in the Keychain. From
/// then on "fill my TIN" names the field and jev types the value. The number
/// itself is never spoken, never transcribed, never journalled, and never sent
/// to a model.
///
/// The property that makes that true is structural rather than careful:
/// **a value never appears in a `Command`.** `.fillDetail` carries the name,
/// the executor looks the value up at the moment it types it, and there is
/// therefore nothing for the journal or an approval card to redact. Redaction
/// is a thing you can forget; an absent field is not.
enum PersonalDetails {

    /// One thing worth keeping.
    struct Field: Sendable, Equatable {
        /// What it is called, out loud and on a card.
        let name: String
        /// Whether seeing it should require a deliberate look.
        ///
        /// Everything here is personal; this marks the ones where the value
        /// itself is the sensitive part rather than merely identifying. It
        /// controls display, never storage — all of them are stored the same
        /// way, which is to say in the Keychain and nowhere else.
        let isSensitive: Bool
    }

    /// The fields jev offers by name.
    ///
    /// A closed list, because it is what the model chooses from. Philippine
    /// ones are here because they are the ones this is being built for; the
    /// rest are the details any form asks for.
    static let known: [Field] = [
        Field(name: "email", isSensitive: false),
        Field(name: "phone", isSensitive: false),
        Field(name: "full name", isSensitive: false),
        Field(name: "address", isSensitive: false),
        Field(name: "city", isSensitive: false),
        Field(name: "postcode", isSensitive: false),
        Field(name: "TIN", isSensitive: true),
        Field(name: "SSS", isSensitive: true),
        Field(name: "PhilHealth", isSensitive: true),
        Field(name: "Pag-IBIG", isSensitive: true),
        Field(name: "passport", isSensitive: true),
        Field(name: "driver's licence", isSensitive: true),
    ]

    static func field(named name: String) -> Field? {
        let wanted = normalise(name)
        return known.first { normalise($0.name) == wanted }
    }

    /// Spoken and written forms of the same name differ in case, spacing and
    /// punctuation — "pag ibig", "Pag-IBIG", "pagibig" are one field.
    static func normalise(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Storage

    /// Keychain accounts are prefixed so a detail can never collide with the
    /// pairing token or anything else jev keeps there.
    static func storageKey(for name: String) -> String { "detail.\(normalise(name))" }

    /// Save a value. The caller typed it; it was never heard.
    static func save(name: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard field(named: name) != nil else { throw Failure.unknownField(name) }
        guard !trimmed.isEmpty else { throw Failure.empty }
        try KeychainManager.shared.store(key: storageKey(for: name), value: trimmed)
        // The name, never the value. This line exists so there is a record
        // that something was set, which a support question needs, and no
        // record of what.
        JevLog.write("[jev] saved a detail: \(canonicalName(name))")
    }

    /// The value, for typing and for nothing else.
    ///
    /// Deliberately not `Codable`, not returned in any API response, and never
    /// interpolated into a log line or a reason string anywhere in jev.
    static func value(for name: String) -> String? {
        guard field(named: name) != nil else { return nil }
        // Timed out, because a Keychain read can raise a prompt and a prompt
        // nobody can answer blocks forever. Reading the whole list at launch
        // wedged the daemon exactly this way.
        return KeychainManager.shared.retrieveWithTimeout(key: storageKey(for: name))
    }

    static func forget(name: String) {
        guard field(named: name) != nil else { return }
        try? KeychainManager.shared.store(key: storageKey(for: name), value: "")
        JevLog.write("[jev] forgot a detail: \(canonicalName(name))")
    }

    /// The names that actually have something behind them.
    ///
    /// This is the closed list the model picks from, so it contains only what
    /// exists: asking someone to choose a field they never filled in produces
    /// a confident answer and nothing to type.
    static func saved() -> [String] {
        known.map(\.name).filter { (value(for: $0)?.isEmpty == false) }
    }

    static func canonicalName(_ spoken: String) -> String {
        field(named: spoken)?.name ?? spoken
    }

    enum Failure: Error, Equatable {
        case unknownField(String)
        case empty
        case notSet(String)
    }

    // MARK: - Keeping them out of what gets sent

    /// The values a scrubber should mask before a page goes to a model.
    ///
    /// A browser task sends every control's label, and on a signed-in page
    /// those labels carry exactly these values — "Deliver to <name>, <city>".
    /// A scrubber finds things by shape and cannot know whose Mac it is on, so
    /// it has to be told, and this is the list to tell it.
    ///
    /// Short values are left out. Masking a two-letter city would rewrite
    /// every page that happens to contain those letters, which corrupts the
    /// page the model is trying to read.
    static let shortestWorthMasking = 4

    static func termsWorthMasking() -> [(name: String, value: String)] {
        known.compactMap { field in
            guard let value = value(for: field.name),
                  value.count >= shortestWorthMasking else { return nil }
            return (name: field.name, value: value)
        }
    }
}
