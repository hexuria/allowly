import Foundation

/// The things on a web page jev will not click without being told to.
///
/// jev already rates button labels, over a list tuned against a hundred and
/// fifty real macOS labels, and that rating covers most of this: purchase,
/// buy, pay, subscribe, confirm, submit, approve, authorise, accept, delete,
/// send. It is not touched here — perturbing it to suit the web would risk
/// every dialog on the Mac.
///
/// What it does not cover is how a shop words the same act. "Place your order"
/// contains none of those words and is the most consequential button on the
/// internet. This is the supplement, and only the supplement.
public enum WebSafety {

    /// Ways of saying "spend the money" that a macOS dialog never has to.
    static let consequentialPhrases = [
        "place order", "place your order", "complete order", "complete purchase",
        "checkout", "check out", "proceed to checkout", "continue to payment",
        "proceed to pay", "pay now", "place bid", "book now", "reserve now",
        "add to cart", "add to basket", "buy it now", "one-click",
        "start free trial", "start trial", "upgrade plan", "renew",
    ]

    /// Whether this label describes something jev should ask about first.
    ///
    /// Substring matching, deliberately: "Proceed to checkout (3 items)" is
    /// the same button as "Proceed to checkout". Over-asking is the safe
    /// direction — a question costs a tap, and the alternative costs money.
    public static func looksConsequential(_ label: String) -> Bool {
        let cleaned = label
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        // A negation inverts it, exactly as it does for a Mac dialog: "Do not
        // renew" is the safe half of a subscription prompt.
        for negation in ["don't ", "do not ", "never ", "cancel "] where cleaned.hasPrefix(negation) {
            return false
        }
        return consequentialPhrases.contains { cleaned.contains($0) }
    }

    /// What the person is asked, for a card.
    ///
    /// Names the button and nothing else. The page wrote that label, so it is
    /// shown as a quoted thing jev found rather than as jev's own words.
    public static func approvalQuestion(for label: String) -> String {
        let tidy = label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = tidy.count > 80 ? String(tidy.prefix(80)) + "…" : tidy
        return "Click “\(shown)”?"
    }
}
