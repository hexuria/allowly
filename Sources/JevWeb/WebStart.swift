import Foundation

/// Where a web task begins.
///
/// The action table a model chooses from contains no "navigate" — the address
/// bar is browser chrome, not part of any page — so something has to decide the
/// first URL before the loop can run at all.
///
/// That decision is deliberately kept away from the model. The whole reason
/// this backend is safe enough to build is that the model only ever picks an
/// index out of a list the code owns; letting it emit a URL instead would hand
/// back exactly the freedom that was withheld, and the first thing a poisoned
/// page would do with it is send the task somewhere else.
///
/// So the start is resolved from, in order: what the person said, matched
/// against a list written here; the page they are already looking at; and
/// otherwise nothing, which is a refusal rather than a guess.
public enum WebStart {

    /// Sites reachable by name, because saying "on YouTube" should work.
    ///
    /// Short on purpose. This is not a directory of the web — it is the set of
    /// places a spoken goal is likely to name, and every entry is a URL a
    /// person can read in a card before anything happens.
    static let knownSites: [(spoken: String, url: String)] = [
        ("youtube", "https://www.youtube.com/"),
        ("amazon", "https://www.amazon.com/"),
        ("github", "https://github.com/"),
        ("wikipedia", "https://www.wikipedia.org/"),
        ("google", "https://www.google.com/"),
        ("gmail", "https://mail.google.com/"),
        ("reddit", "https://www.reddit.com/"),
        ("stack overflow", "https://stackoverflow.com/"),
        ("stackoverflow", "https://stackoverflow.com/"),
        ("hacker news", "https://news.ycombinator.com/"),
        ("linkedin", "https://www.linkedin.com/"),
        ("bluesky", "https://bsky.app/"),
    ]

    public enum Start: Sendable, Equatable {
        /// Navigate here first.
        case url(String)
        /// Begin on whatever the person is already looking at.
        case currentTab
        /// Nothing in the goal named a place and no page was open.
        case unknown
    }

    /// Resolve the starting point from the spoken goal.
    ///
    /// `currentHost` is the frontmost browser tab's host, or nil when the
    /// front app is not a browser — jev already reads this through
    /// `BrowserContext`, and it is passed in so this stays pure and testable.
    public static func resolve(goal: String, currentHost: String?) -> Start {
        let text = goal.lowercased()

        // Longest name first, so "stack overflow" is not beaten by a shorter
        // entry that happens to appear inside it.
        for site in knownSites.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            if mentions(site.spoken, in: text) { return .url(site.url) }
        }

        // A goal that names no site, said while looking at a page, almost
        // always means that page: "reply to this", "open the first result".
        if currentHost != nil { return .currentTab }

        return .unknown
    }

    /// Whether a site is named, on a word boundary.
    ///
    /// Substring matching would fire on "amazon" inside "amazonian" and, worse,
    /// on a hostile page title that the goal happened to quote.
    static func mentions(_ name: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: name, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            // ".com" directly after the name still counts as naming the site.
            if beforeOK && (afterOK || text[found.upperBound...].hasPrefix(".")) { return true }
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Why a task cannot start, in words that say what to do instead.
    public static let cannotStart =
        "Say which site to use, or open the page first."
}
