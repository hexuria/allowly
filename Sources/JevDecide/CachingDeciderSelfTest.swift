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
        screenshot: String? = nil,
        handoff: Bool = false,
        kind: ApprovalKind = .appDialog
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id, kind: kind, title: title, bodyText: body,
            options: options,
            originatingApp: ApplicationInfo(name: "Finder", bundleIdentifier: app),
            timestamp: at, screenshotReference: screenshot, handoffOnly: handoff)
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
            // Both normative in docs/ARCHITECTURE.md (Trust Boundaries): a
            // handoff-only sheet is the one jev must never claim to press.
            ("a handoff-only sheet", DecisionCache.canonical(
                request: request(handoff: true), dialogText: "tree")),
            ("a different kind of request", DecisionCache.canonical(
                request: request(kind: .tccConsent), dialogText: "tree")),
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

        // ---- The model, THROUGH CachingDecider ----
        //
        // The old version of this only exercised `DecisionCache.fingerprint`
        // with two namespace strings, so it passed while the real path put no
        // model in the key at all. Two deciders, two namespaces, one shared
        // ledger: neither may be served the other's answer.
        let shared = DecisionCache(directory: dir.appendingPathComponent("models"))
        let modelA = Counting(ask)
        let modelB = Counting(ask)
        let deciderA = CachingDecider(wrapping: modelA, namespace: "JevDecider/model-a",
                                      cache: shared)
        let deciderB = CachingDecider(wrapping: modelB, namespace: "JevDecider/model-b",
                                      cache: shared)
        _ = await deciderA.decide(request: request(), dialogText: "tree")
        _ = await deciderB.decide(request: request(), dialogText: "tree")
        check("a second model is asked rather than served the first's answer",
              await modelB.count() == 1)
        _ = await deciderA.decide(request: request(), dialogText: "tree")
        check("the first model still hits its own entry", await modelA.count() == 1)

        // ---- A cleared ledger is noticed by a RUNNING cache ----
        //
        // `jevd --clear-decisions` is its own process and cannot reach this
        // map, so without noticing the file has gone a running daemon keeps
        // serving entries that were deleted.
        let clearedDir = dir.appendingPathComponent("cleared")
        let clearedCache = DecisionCache(directory: clearedDir)
        let clearedBackend = Counting(ask)
        let clearedDecider = CachingDecider(wrapping: clearedBackend, namespace: "test",
                                            cache: clearedCache)
        _ = await clearedDecider.decide(request: request(), dialogText: "tree")
        try? FileManager.default.removeItem(at: clearedDir.appendingPathComponent("ledger.jsonl"))
        _ = await clearedDecider.decide(request: request(), dialogText: "tree")
        check("deleting the ledger under a running cache empties it",
              await clearedBackend.count() == 2)

        // ---- Appending must never replace ----
        //
        // The fallback for a FileHandle that would not open used to be
        // `createFile`, which REPLACES the file. One permissions blip would
        // have left a single line where the whole ledger had been.
        let appendDir = dir.appendingPathComponent("append")
        let appendCache = DecisionCache(directory: appendDir)
        let appendDecider = CachingDecider(wrapping: Counting(ask), namespace: "test",
                                           cache: appendCache)
        _ = await appendDecider.decide(request: request(title: "One"), dialogText: "a")
        _ = await appendDecider.decide(request: request(title: "Two"), dialogText: "b")
        let ledger = (try? String(contentsOf: appendDir.appendingPathComponent("ledger.jsonl"),
                                  encoding: .utf8)) ?? ""
        check("a second entry is appended, not written over the first",
              ledger.split(separator: "\n").count == 2)
        check("both entries are in memory too", await appendCache.stats().entries == 2)

        // ---- A cache that cannot be made safe does not cache ----
        //
        // A salt that cannot be saved means a new salt every launch, so every
        // entry is unreadable on the next run. Caching off is the honest
        // answer; a zero salt that still looks salted is not.
        let lockedDir = dir.appendingPathComponent("locked")
        try? FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                ofItemAtPath: lockedDir.path)
        let lockedCache = DecisionCache(directory: lockedDir)
        let lockedBackend = Counting(ask)
        let lockedDecider = CachingDecider(wrapping: lockedBackend, namespace: "test",
                                           cache: lockedCache)
        _ = await lockedDecider.decide(request: request(), dialogText: "tree")
        _ = await lockedDecider.decide(request: request(), dialogText: "tree")
        check("a cache that cannot save its salt says so", await lockedCache.stats().disabled)
        check("and caches nothing at all", await lockedBackend.count() == 2)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                ofItemAtPath: lockedDir.path)

        // ---- A tampered ledger cannot forge an approval ----
        //
        // The rule was enforced on write only, which trusts the file. The
        // file is bytes on a disk: editing one line from "askHuman" to
        // "allow" made a fresh cache hand a forged approval to the caller.
        // 0600 is not the argument — a forged click is worse than a read.
        let tamperDir = dir.appendingPathComponent("tamper")
        let writing = DecisionCache(directory: tamperDir)
        let writingDecider = CachingDecider(wrapping: Counting(ask), namespace: "test",
                                            cache: writing)
        _ = await writingDecider.decide(request: request(), dialogText: "tree")
        let ledgerPath = tamperDir.appendingPathComponent("ledger.jsonl")
        if let honest = try? String(contentsOf: ledgerPath, encoding: .utf8) {
            let forged = honest.replacingOccurrences(of: "\"askHuman\"", with: "\"allow\"")
            check("the tampered line really did change", forged != honest)
            try? forged.write(to: ledgerPath, atomically: true, encoding: .utf8)
        }
        // A brand new cache over the forged file, as a restart would be.
        let reading = DecisionCache(directory: tamperDir)
        let readingBackend = Counting(ask)
        let readingDecider = CachingDecider(wrapping: readingBackend, namespace: "test",
                                            cache: reading)
        let afterTamper = await readingDecider.decide(request: request(), dialogText: "tree")
        check("a forged allow in the ledger is never served",
              afterTamper.value == .askHuman)
        check("and the backend was asked instead", await readingBackend.count() == 1)
        check("the forged line is not kept", await reading.stats().entries == 1)

        // ---- Duplicate keys are compacted, not accumulated ----
        //
        // Compaction triggered only on dropped lines, so three writes of one
        // key left three lines behind a map of one, forever.
        let dupDir = dir.appendingPathComponent("dupes")
        let dupCache = DecisionCache(directory: dupDir)
        let dupPath = dupDir.appendingPathComponent("ledger.jsonl")
        for n in 1...3 {
            // Same key each time: same question, asked again.
            await dupCache.store("same-key", decision: Decision(
                value: .askHuman, confidence: Double(n) / 10, reason: "again", source: .jev))
        }
        let beforeCompaction = ((try? String(contentsOf: dupPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        check("three writes of one key append three lines", beforeCompaction == 3)
        let reopened = DecisionCache(directory: dupDir)
        check("reloading keeps one entry", await reopened.stats().entries == 1)
        let afterCompaction = ((try? String(contentsOf: dupPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        check("and compacts the file down to it", afterCompaction == 1)

        // ---- Clearing forgets the counters too ----
        let countDir = dir.appendingPathComponent("counters")
        let countCache = DecisionCache(directory: countDir)
        let countDecider = CachingDecider(wrapping: Counting(ask), namespace: "test",
                                          cache: countCache)
        _ = await countDecider.decide(request: request(), dialogText: "tree")
        _ = await countDecider.decide(request: request(), dialogText: "tree")
        check("a hit and a miss were counted", await countCache.stats().hits == 1)
        try? FileManager.default.removeItem(at: countDir.appendingPathComponent("ledger.jsonl"))
        _ = await countDecider.decide(request: request(), dialogText: "tree")
        check("clearing the ledger resets the counters too, so the two paths agree",
              await countCache.stats().hits == 0)

        // ---- Per-schema salt ----
        check("one master salt gives different schemas different salts",
              DecisionCache.salt(master: "m", schema: "approval.v1")
                != DecisionCache.salt(master: "m", schema: "utterance.v1"))
        check("the same schema and master is the same salt",
              DecisionCache.salt(master: "m", schema: "approval.v1")
                == DecisionCache.salt(master: "m", schema: "approval.v1"))
        check("a different master changes it",
              DecisionCache.salt(master: "n", schema: "approval.v1")
                != DecisionCache.salt(master: "m", schema: "approval.v1"))
        check("an unlisted schema still gets the default month",
              DecisionCache.ttl(for: "anything") == DecisionCache.defaultTTL)

        return failures
    }
}
