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
    private let cache: DecisionCache

    /// - Parameter namespace: what produced the answers — the decider and its
    ///   model. Answers from one model must never be served to another, so it
    ///   goes into the key rather than being assumed constant.
    public init(wrapping decider: any Decider,
                namespace: String,
                cache: DecisionCache? = nil) {
        self.wrapped = decider
        self.cache = cache ?? DecisionCache.shared
        Task { [cache = self.cache] in await cache.load() }
    }

    public func decide(request: ApprovalRequest, dialogText: String) async -> Decision {
        let key = await cache.key(for: request, dialogText: dialogText, namespace: namespaceKey)
        if let remembered = await cache.lookup(key) {
            return remembered
        }
        let fresh = await wrapped.decide(request: request, dialogText: dialogText)
        await cache.store(key, decision: fresh)
        return fresh
    }

    private var namespaceKey: String { String(describing: type(of: wrapped)) }
}

/// The ledger. One file, no daemon, no port, no network.
public actor DecisionCache {

    public static let shared = DecisionCache()

    /// Bump when what goes into a key changes, which retires every old entry
    /// rather than serving answers computed from a different question.
    public static let schemaVersion = "approval.v1"

    /// How long an answer is trusted. A month is long enough to matter on a
    /// path you hit daily and short enough that a stale answer ages out
    /// rather than being inherited by next year's version of the app.
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry: Codable {
        let key: String
        let decision: Decision
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var salt: String = ""
    private var loaded = false
    private let ttl: TimeInterval
    private let directory: URL

    private(set) public var hits = 0
    private(set) public var misses = 0

    public init(directory: URL? = nil, ttl: TimeInterval = DecisionCache.defaultTTL) {
        self.ttl = ttl
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/decisions")
    }

    private var ledgerURL: URL { directory.appendingPathComponent("ledger.jsonl") }
    private var saltURL: URL { directory.appendingPathComponent("salt") }

    // MARK: - The key

    /// What the answer actually depends on, listed rather than filtered.
    ///
    /// An allowlist, not a scrubber, and the difference is the whole safety
    /// argument. A generic "mask long digit runs" — which is the right move
    /// for a support ticket — would put `type 4 0 2` and `type 8 1 9` on the
    /// same key here. A wrong cached decision is worse than a slow one: it is
    /// permanent, and it looks confident.
    ///
    /// Two fields are deliberately absent. `id` is a fresh UUID per request
    /// and `timestamp` is the moment it arrived; including either would make
    /// every key unique and the hit rate exactly zero. `screenshotReference`
    /// is a path to a file, not a fact about the question.
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
        return Self.fingerprint(namespace: namespace, salt: salt,
                         canonical: Self.canonical(request: request, dialogText: dialogText))
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
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let stored = try? String(contentsOf: saltURL, encoding: .utf8),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            salt = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            salt = Data(bytes).base64EncodedString()
            FileManager.default.createFile(atPath: saltURL.path,
                                           contents: Data(salt.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }

        guard let text = try? String(contentsOf: ledgerURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data) else { continue }
            // Append-only, so a key written twice is the later one.
            guard now.timeIntervalSince(entry.storedAt) < ttl else { continue }
            entries[entry.key] = entry
        }
    }

    public func lookup(_ key: String) -> Decision? {
        load()
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.storedAt) < ttl else {
            misses += 1
            return nil
        }
        hits += 1
        return entry.decision
    }

    public func store(_ key: String, decision: Decision) {
        guard Self.isCacheable(decision) else { return }
        load()
        let entry = Entry(key: key, decision: decision, storedAt: Date())
        entries[key] = entry
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: ledgerURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            // 0600 from birth: this records what your Mac was asked to do.
            FileManager.default.createFile(atPath: ledgerURL.path,
                                           contents: Data(line.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    public func clear() {
        entries.removeAll()
        hits = 0
        misses = 0
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    /// For the launch self-test line.
    public func stats() -> (entries: Int, hits: Int, misses: Int) {
        load()
        return (entries.count, hits, misses)
    }

    /// Wipe the ledger from a terminal, without launching the app.
    public static func clearOnDisk() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/decisions")
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        let existed = FileManager.default.fileExists(atPath: ledger.path)
        try? FileManager.default.removeItem(at: ledger)
        return existed ? "Cleared \(ledger.path)" : "Nothing to clear at \(ledger.path)"
    }
}
