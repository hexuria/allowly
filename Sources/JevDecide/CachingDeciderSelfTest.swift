import Foundation
import JevCore

/// Checks the two things that make a decision cache safe rather than clever:
/// that an approval is never written down, and that a key means exactly one
/// question.
///
/// The second matters as much as the first. A key that ignores too much serves
/// yesterday's answer to today's question — permanently, and confidently. A key
/// that ignores too little never hits at all, which is merely useless.
public enum CachingDeciderSelfTest {

    /// A decider that always answers the same way, and counts how often it was
    /// actually asked. That count is the only way to tell a cache hit from a
    /// cache that is quietly doing nothing.
    private actor Counting: Decider {
        private(set) var calls = 0
        private let answer: Decision
        init(_ answer: Decision) { self.answer = answer }
        func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
            calls += 1
            return answer
        }
        func count() -> Int { calls }
    }

    private static func request(
        id: String = "id-1",
        title: String = "Delete the folder?",
        body: String = "This cannot be undone.",
        app: String = "com.apple.Finder",
        options: [ApprovalOption] = [
            ApprovalOption(id: "delete", label: "Delete", riskLevel: .high),
            ApprovalOption(id: "cancel", label: "Cancel", riskLevel: .low),
        ],
        at: Date = Date(timeIntervalSince1970: 1_700_000_000),
        screenshot: String? = nil
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id, kind: .appDialog, title: title, bodyText: body,
            options: options,
            originatingApp: ApplicationInfo(name: "Finder", bundleIdentifier: app),
            timestamp: at, screenshotReference: screenshot, handoffOnly: false)
    }

    public static func run() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("cache: \(name)") }
        }

        // ---- What may be written down ----
        let ask = Decision(value: .askHuman, confidence: 0.5, reason: "unclear", source: .jev)
        let allow = Decision(value: .allow, chosenOptionId: "delete", confidence: 0.99,
                             reason: "looks routine", source: .jev)
        let deny = Decision(value: .deny, confidence: 0.99, reason: "destructive", source: .jev)
        check("“ask them” is cacheable", DecisionCache.isCacheable(ask))
        check("an allow is never cacheable", !DecisionCache.isCacheable(allow))
        check("a deny is never cacheable", !DecisionCache.isCacheable(deny))
        for source in [DecisionSource.jev, .policy, .human] {
            check("an allow from \(source.rawValue) is still never cacheable",
                  !DecisionCache.isCacheable(Decision(value: .allow, confidence: 1,
                                                      reason: "", source: source)))
        }

        // ---- An allow must not round-trip, even through a real store ----
        //
        // The assertion the issue asks for. Asked twice, answered `allow`
        // both times, the wrapped decider must have been called BOTH times:
        // a cached allow is a click on somebody's Mac that nobody authorised
        // today.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let allowCache = DecisionCache(directory: dir.appendingPathComponent("allow"))
        let allowBackend = Counting(allow)
        let allowDecider = CachingDecider(wrapping: allowBackend, namespace: "test",
                                          cache: allowCache)
        _ = await allowDecider.decide(request: request(), dialogText: "tree")
        _ = await allowDecider.decide(request: request(), dialogText: "tree")
        check("an allow is asked again rather than remembered",
              await allowBackend.count() == 2)
        check("nothing was stored for an allow", await allowCache.stats().entries == 0)

        // ---- And "ask them" must round-trip ----
        let askCache = DecisionCache(directory: dir.appendingPathComponent("ask"))
        let askBackend = Counting(ask)
        let askDecider = CachingDecider(wrapping: askBackend, namespace: "test", cache: askCache)
        let first = await askDecider.decide(request: request(), dialogText: "tree")
        let second = await askDecider.decide(request: request(), dialogText: "tree")
        check("the same question is only asked once", await askBackend.count() == 1)
        check("the remembered answer is the same answer",
              first.value == second.value && second.value == .askHuman)
        check("one entry was stored", await askCache.stats().entries == 1)
        await askCache.clear()
        check("clearing empties it", await askCache.stats().entries == 0)
        _ = await askDecider.decide(request: request(), dialogText: "tree")
        check("after clearing, the backend is asked again", await askBackend.count() == 2)

        // ---- What the key ignores, and must ignore ----
        //
        // A fresh UUID and a new timestamp arrive with every request. Putting
        // either in the key makes every key unique and the hit rate exactly
        // zero — a cache that stores forever and never once answers.
        let base = DecisionCache.canonical(request: request(), dialogText: "tree")
        check("a different request id is the same question",
              DecisionCache.canonical(request: request(id: "id-2"), dialogText: "tree") == base)
        check("a different arrival time is the same question",
              DecisionCache.canonical(request: request(at: Date()), dialogText: "tree") == base)
        check("a screenshot path is the same question",
              DecisionCache.canonical(request: request(screenshot: "/tmp/a.png"),
                                      dialogText: "tree") == base)
        check("whitespace is not a question",
              DecisionCache.canonical(request: request(title: " Delete   the\nfolder? "),
                                      dialogText: "tree") == base)

        // ---- What the key must NOT ignore ----
        //
        // Every one of these changes the right answer, so every one must
        // change the key. A generic PII scrubber would collapse the digit
        // cases together, which is exactly the collision to avoid.
        let mustDiffer: [(String, String)] = [
            ("a different title", DecisionCache.canonical(request: request(title: "Empty the bin?"),
                                                          dialogText: "tree")),
            ("a different body", DecisionCache.canonical(request: request(body: "Are you sure?"),
                                                         dialogText: "tree")),
            ("a different app", DecisionCache.canonical(request: request(app: "com.google.Chrome"),
                                                        dialogText: "tree")),
            ("a different dialog tree", DecisionCache.canonical(request: request(),
                                                                dialogText: "other")),
            ("different buttons", DecisionCache.canonical(request: request(options: [
                ApprovalOption(id: "ok", label: "OK", riskLevel: .low)]), dialogText: "tree")),
            ("the same buttons in the other order", DecisionCache.canonical(request: request(options: [
                ApprovalOption(id: "cancel", label: "Cancel", riskLevel: .low),
                ApprovalOption(id: "delete", label: "Delete", riskLevel: .high)]),
                dialogText: "tree")),
            ("the same button with a different risk", DecisionCache.canonical(request: request(options: [
                ApprovalOption(id: "delete", label: "Delete", riskLevel: .low),
                ApprovalOption(id: "cancel", label: "Cancel", riskLevel: .low)]),
                dialogText: "tree")),
        ]
        for (name, candidate) in mustDiffer {
            check("\(name) is a different question", candidate != base)
        }

        // Digits especially. `type 4 0 2` and `type 8 1 9` landing on one key
        // is the failure this cache is written to avoid.
        let four = DecisionCache.canonical(request: request(body: "type 4 0 2"), dialogText: "t")
        let eight = DecisionCache.canonical(request: request(body: "type 8 1 9"), dialogText: "t")
        check("two different numbers are two different questions", four != eight)

        // ---- Salt and namespace ----
        check("the same question under a different salt is a different key",
              DecisionCache.fingerprint(namespace: "n", salt: "a", canonical: base)
                != DecisionCache.fingerprint(namespace: "n", salt: "b", canonical: base))
        check("an answer from one model is not served for another",
              DecisionCache.fingerprint(namespace: "modelA", salt: "s", canonical: base)
                != DecisionCache.fingerprint(namespace: "modelB", salt: "s", canonical: base))
        check("the same question, salt and model is the same key",
              DecisionCache.fingerprint(namespace: "n", salt: "s", canonical: base)
                == DecisionCache.fingerprint(namespace: "n", salt: "s", canonical: base))

        // ---- Age ----
        let expiring = DecisionCache(directory: dir.appendingPathComponent("ttl"), ttl: -1)
        let expiringBackend = Counting(ask)
        let expiringDecider = CachingDecider(wrapping: expiringBackend, namespace: "test",
                                             cache: expiring)
        _ = await expiringDecider.decide(request: request(), dialogText: "tree")
        _ = await expiringDecider.decide(request: request(), dialogText: "tree")
        check("an answer past its time is asked again", await expiringBackend.count() == 2)

        return failures
    }
}
