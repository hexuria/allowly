import Foundation

/// One reading of the page, and the evidence needed to tell whether it is
/// still true.
///
/// `marker`, `pageKey` and `guards` are not for the model — it never sees
/// them. They exist so that between deciding and acting, jev can ask the page
/// whether it still means what it meant. A decision made about a list that has
/// since reordered is not a decision about this page any more, and acting on
/// it clicks whatever slid into that position.
public struct WebSnapshot: Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let actions: [WebAction]
    public let omittedActions: Int
    public let payloadBytes: Int

    /// Which document this reading belongs to.
    ///
    /// `performance.timeOrigin`, which snapshot.js already computes as the
    /// head of both `marker` and `page_key`. A URL is not an identity: a
    /// reload, a same-address navigation, or a redirect that lands back where
    /// it started all give a new document with the same `location.href`, and
    /// snapshot.js allocates node ids from 1 again in each one. Comparing
    /// addresses therefore says two different documents are the same.
    let documentToken: Double?

    /// Whole-page semantic identity: document, scroll, viewport, title, text
    /// and every action's meaning.
    let marker: Data?
    /// Form state only — values, checked, disabled — which is what changes
    /// under a click without the page as a whole changing.
    let pageKey: Data?
    /// Per node: its role, name, value, state and the text of the form, row
    /// or dialog it sits in.
    let guards: [String: Data]
    /// Per input node: its value and state. The guards cannot see these —
    /// `innerText` does not include what is typed into a field — so without
    /// them a form whose contents changed under us looks untouched.
    let inputStates: [String: Data]

    public var page: WebPage { WebPage(url: url, title: title, text: text) }

    init?(value: [String: Any]) {
        guard let url = value["url"] as? String else { return nil }
        self.url = url
        self.title = (value["title"] as? String) ?? ""
        self.text = (value["text"] as? String) ?? ""
        self.actions = ((value["actions"] as? [[String: Any]]) ?? []).compactMap(WebAction.init(json:))
        self.omittedActions = (value["omitted_actions"] as? Int) ?? 0
        self.payloadBytes = (try? JSONSerialization.data(withJSONObject: value).count) ?? 0

        self.documentToken = (value["marker"] as? [Any])?.first as? Double
        self.marker = Self.canonical(value["marker"])
        self.pageKey = Self.canonical(value["page_key"])

        // page_key's tail is every safe input on the page as
        // [id, value, checked, selectedIndex, disabled, readOnly], keyed by
        // the same node identity the guards use. Kept per id so a freshness
        // check can compare just the fields belonging to one form rather than
        // the whole page.
        var inputStates: [String: Data] = [:]
        if let key = value["page_key"] as? [Any], key.count >= 7,
           let inputs = key[6] as? [[Any]] {
            for entry in inputs where !entry.isEmpty {
                guard let id = entry[0] as? Int else { continue }
                inputStates[String(id)] = Self.canonical(entry)
            }
        }
        self.inputStates = inputStates

        var guards: [String: Data] = [:]
        for (node, guardValue) in (value["guards"] as? [String: Any]) ?? [:] {
            guards[node] = Self.canonical(guardValue)
        }
        self.guards = guards
    }

    /// Compare by bytes, not by `==` on `Any`.
    ///
    /// These structures are arrays of mixed nulls, numbers, strings and nested
    /// arrays, which Swift cannot equate directly. Serialising both sides the
    /// same way makes the comparison exact and total — and exactness is the
    /// point, since a guard that compares loosely is a guard that passes when
    /// the page has changed.
    static func canonical(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: value,
                                           options: [.fragmentsAllowed, .sortedKeys])
    }
}
