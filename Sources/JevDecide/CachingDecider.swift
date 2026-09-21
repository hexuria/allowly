import Foundation
import CryptoKit
import JevCore

/// Remember what Jev said, so the same question is not paid for twice.
///
/// A decision is close to a pure function of (model, schema, state), and the
/// same states come round constantly — the same dialog from the same app, the
/// same sentence said again because nothing appeared to happen. Each one costs
/// a network round trip and a fraction of a cent, and answers the same way.
///
/// ## The rule that matters: an approval is never cached
///
/// "Compute once, remember forever" is fine for routing a support ticket and
/// wrong for something that clicks Allow on a real Mac. So only `.askHuman` is
/// ever written down. That is stricter than it needs to be — the issue only
/// rules out `allow`/`deny` from the model — and the strictness is the point:
/// a rule of "cache exactly one value" cannot be got subtly wrong later, where
/// "cache everything except these cases" can.
///
/// jev already has the right kind of memory for an approval, and it is better
/// than a hash ledger precisely because a person can read it and revoke it:
/// `Policy` and `AppPolicyStore`, reached from the card's long-press sheet.
/// Policy is deliberate, visible and reversible. A fingerprint ledger is
/// accidental, opaque and permanent.
///
/// Caching `.askHuman` still earns its place: a repeated ambiguous dialog stops
/// costing a round trip to be told, again, to ask you.
public struct CachingDecider: Decider {

    private let wrapped: any Decider
    private let namespace: String
    private let cache: DecisionCache

    /// - Parameter namespace: what produced the answers — the decider AND its
    ///   model. An answer computed by one model must never be served for
    ///   another, so it goes into the key.
    ///
    ///   This was accepted and then silently dropped: the key used the wrapped
    ///   type's name, which is the same string whatever model is configured,
    ///   so changing models would have served the old model's answers forever.
    ///   The self-test missed it by exercising `DecisionCache.fingerprint`
    ///   directly rather than going through here — a test that passed while
    ///   the real path had no model in the key at all. It is asserted through
    ///   `CachingDecider` now.
    public init(wrapping decider: any Decider,
                namespace: String,
                cache: DecisionCache? = nil) {
        self.wrapped = decider
        self.namespace = namespace
        self.cache = cache ?? DecisionCache.shared
    }

    /// Known and accepted: two identical requests arriving together both
    /// miss and both reach the backend, because the lookup and the store are
    /// separate hops on an actor that suspends between them. It costs a
    /// second call, never a wrong answer, and coalescing would mean moving
    /// the backend call inside the actor — a bigger change than the saving
    /// justifies at the rate dialogs actually arrive.
    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        let key = await cache.key(for: request, dialogText: dialogText, namespace: namespace)
        if let remembered = await cache.lookup(key) {
            return remembered
        }
        let fresh = await wrapped.decide(request: request, dialogText: dialogText)
        await cache.store(key, decision: fresh)
        return fresh
    }
}

/// The ledger. One file, no daemon, no port, no network.
public actor DecisionCache {

    public static let shared = DecisionCache()

    /// Where a line about the cache goes. JevDecide cannot see `JevLog`, so
    /// the daemon hands one in at startup — the same arrangement `CuaDriver`
    /// uses.
    nonisolated(unsafe) public static var log: @Sendable (String) -> Void = { _ in }

    /// Bump when what goes into a key changes, which retires every old entry
    /// rather than serving answers computed from a different question.
    public static let schemaVersion = "approval.v1"

    /// How long an answer is trusted, per schema. A month is long enough to
    /// matter on a path you hit daily and short enough that a stale answer
    /// ages out rather than being inherited by next year's version of the app.
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60
    /// Per-schema overrides. Empty today because there is one schema — this
    /// is the place to put a second one's TTL, not a derivation.
    private static let ttlBySchema: [String: TimeInterval] = [:]

    public static func ttl(for schema: String) -> TimeInterval {
        ttlBySchema[schema] ?? defaultTTL
    }

    private struct Entry: Codable {
        let key: String
        let decision: Decision
        let storedAt: Date
    }

    private struct Counters: Codable {
        var hits: Int
        var misses: Int
    }

    private var entries: [String: Entry] = [:]
    private var masterSalt: String = ""
    private var loaded = false
    /// Set when the cache cannot be made safe. See `load`.
    private var disabled = false
    private let ttlOverride: TimeInterval?
    private let directory: URL

    private(set) public var hits = 0
    private(set) public var misses = 0

    /// - Parameter ttl: for tests. Production TTL comes from the schema.
    public init(directory: URL? = nil, ttl: TimeInterval? = nil) {
        self.ttlOverride = ttl
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/decisions")
    }

    private var ledgerURL: URL { directory.appendingPathComponent("ledger.jsonl") }
    private var saltURL: URL { directory.appendingPathComponent("salt") }
    private var countersURL: URL { directory.appendingPathComponent("counters.json") }

    private func ttl(for schema: String) -> TimeInterval {
        ttlOverride ?? Self.ttl(for: schema)
    }

    // MARK: - The key

    /// What the answer actually depends on, listed rather than filtered.
    ///
    /// An allowlist, not a scrubber, and the difference is the whole safety
    /// argument. A generic "mask long digit runs" — which is the right move
    /// for a support ticket — would put `type 4 0 2` and `type 8 1 9` on the
    /// same key here. A wrong cached decision is worse than a slow one: it is
    /// permanent, and it looks confident.
    ///
    /// Four fields are deliberately absent. `id` is a fresh UUID per request
    /// and `timestamp` is the moment it arrived; including either would make
    /// every key unique and the hit rate exactly zero. `screenshotReference`
    /// is a path to a file, not a fact about the question. And the app's
    /// display `name` is localised, where its bundle identifier is not — two
    /// Macs in two languages should agree about what the same question is.
    public static func canonical(request: ApprovalRequest, dialogText: String) -> String {
        func flat(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // Options in the order they are offered: a dialog whose buttons are
        // the same words in a different order is a different dialog.
        let options = request.options
            .map { "\($0.id)\u{1F}\(flat($0.label))\u{1F}\($0.riskLevel.rawValue)" }
            .joined(separator: "\u{1E}")
        let fields = [
            "kind=\(request.kind.rawValue)",
            "app=\(request.originatingApp.bundleIdentifier)",
            "handoff=\(request.handoffOnly)",
            "title=\(flat(request.title))",
            "body=\(flat(request.bodyText))",
            "options=\(options)",
            "dialog=\(flat(dialogText))",
        ]
        // Sorted, so a reordering of this array can never change a key.
        return fields.sorted().joined(separator: "\u{1D}")
    }

    func key(for request: ApprovalRequest, dialogText: String, namespace: String) -> String {
        // Before anything, because the salt is part of the key and is read
        // from disk by `load`. Without this the first key of the process was
        // built with an empty salt and every later one with the real salt, so
        // an answer was stored under a key that could never be looked up
        // again — a cache that wrote a file and never once answered from it.
        load()
        return Self.fingerprint(namespace: namespace,
                                salt: Self.salt(master: masterSalt, schema: Self.schemaVersion),
                                canonical: Self.canonical(request: request, dialogText: dialogText))
    }

    /// Per schema, derived rather than stored.
    ///
    /// One master salt on disk, one derived salt per schema. A second schema
    /// therefore cannot inherit the first's salt, and adding one needs no new
    /// file and no migration.
    public static func salt(master: String, schema: String) -> String {
        SHA256.hash(data: Data("\(master)\u{1D}\(schema)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Salted, so the ledger cannot be enumerated by guessing states.
    public static func fingerprint(namespace: String, salt: String, canonical: String) -> String {
        let material = "\(namespace)\u{1D}\(schemaVersion)\u{1D}\(salt)\u{1D}\(canonical)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The rule

    /// Only "ask them" is ever written down. See `CachingDecider`.
    public static func isCacheable(_ decision: Decision) -> Bool {
        decision.value == .askHuman
    }

    // MARK: - Reading and writing

    public func load() {
        if loaded {
            // The ledger can be deleted from a terminal — `jevd
            // --clear-decisions` runs as its own process and cannot reach this
            // map. Without this check a running daemon kept serving entries
            // that had already been wiped, so "empties it" quietly meant
            // "empties it after you restart".
            if !entries.isEmpty, !FileManager.default.fileExists(atPath: ledgerURL.path) {
                // Counted BEFORE the clear. Read after `removeAll` this said
                // "forgetting 0" every single time.
                let forgotten = entries.count
                entries.removeAll()
                // `clearOnDisk` removes the counters too, so a live daemon
                // that kept its own would rewrite them on the next lookup
                // and the two paths would disagree about what "cleared" means.
                hits = 0
                misses = 0
                Self.log("[jev] decisions: ledger was cleared underneath us; forgetting \(forgotten)")
            }
            return
        }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let stored = try? String(contentsOf: saltURL, encoding: .utf8),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            masterSalt = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            // Checked, like the pairing token in main.swift. An ignored
            // failure leaves sixteen zero bytes, which is a FIXED salt — the
            // ledger becomes enumerable by anyone who can guess states, while
            // the comment above still claims it is salted. A cache that
            // cannot be made safe must not cache.
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                disabled = true
                Self.log("[jev] decisions: no random bytes for a salt; caching is off this session")
                return
            }
            masterSalt = Data(bytes).base64EncodedString()
            // Also checked. A salt that never reaches disk means a new one
            // every launch, so every entry written is unreadable on the next
            // run and the file grows forever holding nothing usable.
            guard FileManager.default.createFile(atPath: saltURL.path,
                                                 contents: Data(masterSalt.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                disabled = true
                Self.log("[jev] decisions: could not save the salt; caching is off this session")
                return
            }
        }

        if let data = try? Data(contentsOf: countersURL),
           let counters = try? JSONDecoder().decode(Counters.self, from: data) {
            hits = counters.hits
            misses = counters.misses
        }

        guard let text = try? String(contentsOf: ledgerURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()
        var dropped = false
        var kept = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data) else { dropped = true; continue }
            // The rule is enforced on READ as well as on write.
            //
            // Guarding only `store` trusts the file, and the file is just
            // bytes on a disk. Editing one line from "askHuman" to "allow"
            // made a fresh cache hand a forged approval to the caller —
            // demonstrated, not imagined. 0600 is not the argument: the salt
            // comment below already treats a same-user reader as in scope,
            // and a forged click is worse than an enumerated ledger.
            guard Self.isCacheable(entry.decision) else { dropped = true; continue }
            // Append-only, so a key written twice is the later one.
            guard now.timeIntervalSince(entry.storedAt) < ttl(for: Self.schemaVersion) else {
                dropped = true
                continue
            }
            entries[entry.key] = entry
            kept += 1
        }
        // Compaction, for both ways the file outgrows the map it produces:
        // lines that were dropped, and lines superseded by a later write of
        // the same key. Triggering on `dropped` alone left a ledger of three
        // lines behind a map of one, forever.
        if dropped || kept > entries.count { rewriteLedger() }
    }

    public func lookup(_ key: String) -> Decision? {
        load()
        guard !disabled else { return nil }
        guard let entry = entries[key],
              // Belt and braces with the check in `load`. Anything that is
              // not "ask them" is not servable, however it got here.
              Self.isCacheable(entry.decision),
              Date().timeIntervalSince(entry.storedAt) < ttl(for: Self.schemaVersion) else {
            misses += 1
            saveCounters()
            return nil
        }
        hits += 1
        saveCounters()
        return entry.decision
    }

    public func store(_ key: String, decision: Decision) {
        guard Self.isCacheable(decision) else { return }
        load()
        guard !disabled else { return }
        let entry = Entry(key: key, decision: decision, storedAt: Date())
        entries[key] = entry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        append(line + "\n")
    }

    /// Add one line, and never replace the file.
    ///
    /// `createFile` REPLACES whatever is there. Using it as the fallback for a
    /// `FileHandle` that would not open meant one permissions blip or one
    /// exhausted descriptor table wiped every entry and left a single line
    /// behind. Missing is the only case that may create.
    private func append(_ line: String) {
        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            // 0600 from birth: this records what your Mac was asked to do.
            if !FileManager.default.createFile(atPath: ledgerURL.path,
                                               contents: Data(line.utf8),
                                               attributes: [.posixPermissions: 0o600]) {
                Self.log("[jev] decisions: could not create the ledger; this one stays in memory")
            }
            return
        }
        guard let handle = try? FileHandle(forWritingTo: ledgerURL) else {
            Self.log("[jev] decisions: ledger is there but will not open; this one stays in memory")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func rewriteLedger() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = entries.values
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let text = body.isEmpty ? "" : body + "\n"
        try? text.write(to: ledgerURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: ledgerURL.path)
    }

    private func saveCounters() {
        guard let data = try? JSONEncoder().encode(Counters(hits: hits, misses: misses)) else { return }
        try? data.write(to: countersURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: countersURL.path)
    }

    public func clear() {
        load()
        entries.removeAll()
        hits = 0
        misses = 0
        try? FileManager.default.removeItem(at: ledgerURL)
        try? FileManager.default.removeItem(at: countersURL)
    }

    /// For the launch line. Counters are lifetime, read back from disk, so a
    /// cache that has stopped working is visible rather than merely cheap.
    public func stats() -> (entries: Int, hits: Int, misses: Int, disabled: Bool) {
        load()
        return (entries.count, hits, misses, disabled)
    }

    /// Wipe the ledger from a terminal, without launching the app. A daemon
    /// already running notices on its next lookup — see `load`.
    public static func clearOnDisk() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/decisions")
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        let counters = dir.appendingPathComponent("counters.json")
        let existed = FileManager.default.fileExists(atPath: ledger.path)
        try? FileManager.default.removeItem(at: ledger)
        try? FileManager.default.removeItem(at: counters)
        return existed ? "Cleared \(ledger.path)" : "Nothing to clear at \(ledger.path)"
    }
}
