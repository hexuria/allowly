import Foundation

/// "Don't Save" is not a longer way of saying "Save".
///
/// Narrow on purpose, because two wider attempts were both wrong.
///
/// The matchers fall back from exact equality to a single unambiguous
/// partial match, and the question is which partial matches are safe. The
/// answer turned out to be structural rather than lexical: **a candidate
/// may only ADD TO THE END of what was asked for.**
///
///   Replace            -> Replace Existing     narrowing, allowed
///   Сохранить          -> Сохранить изменения  narrowing, allowed
///   Save               -> Don't Save           refused: adds at the front
///   Download           -> Cancel Download      refused: adds at the front
///   Install            -> Uninstall            refused: adds at the front
///   Invoice            -> Approve / Discard    refused: adds at the front
///
/// That one rule replaces a list of negation words that kept being both
/// too wide and too narrow — it let `Un`install through, and it read
/// "Discard Invoice" as the negation of "Invoice" when it is simply one
/// of two things you can do to an invoice.
///
/// What it does NOT catch is a language that negates at the END, where
/// the inversion really is a suffix. That is what this type is still for.
public enum Negation {

    /// Negation that arrives after the word it reverses, in scripts that
    /// do not space their words — so a suffix match cannot be trusted.
    /// Deliberately specific: `안` alone matched 안전 ("safe") and `не`
    /// alone matched изменения.
    private static let trailing = ["しない", "ません", "하지 않", "안 함", "않음",
                                   "없음", "취소"]

    /// Separate words that reverse what they precede.
    private static let words: Set<String> = [
        "don't", "dont", "not", "never", "no",
        "nicht", "kein", "keine", "nein",
        "pas", "non", "aucun",
        "nunca", "niet", "nee", "geen",
    ]

    /// Does this text carry a negation?
    public static func isNegated(_ text: String) -> Bool {
        let lower = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        for marker in trailing where lower.contains(marker) { return true }
        let tokens = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })
        return tokens.contains { words.contains(String($0)) }
    }

    /// Do these two disagree about being a negation?
    ///
    /// Asked of a candidate that already starts with the request, so the
    /// only inversion left to catch is one bolted on the end.
    public static func differs(_ wanted: String, _ candidate: String) -> Bool {
        isNegated(wanted) != isNegated(candidate)
    }
}
