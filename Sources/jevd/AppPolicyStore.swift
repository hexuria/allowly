import Foundation
import JevCore

/// What jev should do the next time you ask for a given app.
enum AppMode: String, Codable, Sendable, CaseIterable {
    /// Run it without asking.
    case always
    /// Refuse without asking.
    case never
    /// Let the decision model judge each request on its merits.
    case auto
}

/// How jev behaves for anything without an explicit per-app choice.
enum GlobalMode: String, Codable, Sendable, CaseIterable {
    /// Prompt every time. The safe starting point.
    case ask
    /// Run anything not explicitly set to never. The blacklist governs.
    case allowAll
    /// Let Jev judge anything without an explicit choice.
    case auto
    /// Refuse anything not explicitly set to always. The whitelist governs.
    case denyAll

    var explanation: String {
        switch self {
        case .ask: return "Ask me about anything I have not already decided"
        case .allowAll: return "Allow everything except what I have blocked"
        case .auto: return "Let Allowly decide anything I have not already decided"
        case .denyAll: return "Block everything except what I have allowed"
        }
    }
}

/// Per-app decisions, remembered across restarts.
///
/// Replaces the flat allowlist: "allowed or not" could not express "ask the
/// model" or "never bother me about this again".
final class AppPolicyStore: @unchecked Sendable {
    static let shared = AppPolicyStore()

    private let lock = NSLock()
    private var modes: [String: AppMode] = [:]
    // Auto by default. Asking about everything is the safe starting point but
    // a miserable steady state; the point of having a decision model is that
    // it decides.
    private var global: GlobalMode = .auto

    private static var fileURL: URL {
        Allowly.supportDirectory.appendingPathComponent("app-modes.json")
    }

    private static var legacyAllowlistURL: URL {
        Allowly.supportDirectory.appendingPathComponent("allowlist.json")
    }

    init() { load() }

    /// An explicit per-app choice, if one exists.
    func mode(for bundleIdentifier: String) -> AppMode? {
        lock.lock(); defer { lock.unlock() }
        return modes[bundleIdentifier]
    }

    var globalMode: GlobalMode {
        lock.lock(); defer { lock.unlock() }
        return global
    }

    func setGlobal(_ mode: GlobalMode) {
        lock.lock()
        global = mode
        let snapshot = (modes, global)
        lock.unlock()
        save(snapshot.0, global: snapshot.1)
        JevLog.write("[allowly] default policy -> \(mode.rawValue)")
    }

    /// What to do about an app, taking the global default into account.
    /// An explicit per-app choice always wins: that is what makes the
    /// per-app list a whitelist under denyAll and a blacklist under allowAll.
    func effectiveMode(for bundleIdentifier: String) -> AppMode? {
        if let explicit = mode(for: bundleIdentifier) { return explicit }
        switch globalMode {
        case .ask: return nil
        case .allowAll: return .always
        case .auto: return .auto
        case .denyAll: return .never
        }
    }

    /// What a policy saved under the OLD shared key still means.
    ///
    /// Typing and clicking used to be filed under "system.keyboard" and
    /// "system.pointer" whatever app they landed in, and are granted per app
    /// now. That move must not quietly change what someone already decided,
    /// and the two directions are not symmetric:
    ///
    ///   * `never` still refuses. A refusal is never widened by a refactor —
    ///     someone who turned typing off does not get it back because the key
    ///     it was stored under was renamed.
    ///   * `always` no longer grants, because a blanket "allow typing" is
    ///     exactly the hole being closed: it covered a terminal and a bank
    ///     alike. It is retired out loud rather than silently, and the person
    ///     can allow the app itself the next time a card asks.
    ///
    /// Pure, and asserted, because getting this backwards re-enables
    /// something that was deliberately switched off.
    static func inherited(bucket: AppMode?) -> AppMode? {
        bucket == .never ? .never : nil
    }

    func forget(_ bundleIdentifier: String) {
        lock.lock()
        modes.removeValue(forKey: bundleIdentifier)
        let snapshot = (modes, global)
        lock.unlock()
        save(snapshot.0, global: snapshot.1)
        JevLog.write("[allowly] forgot \(bundleIdentifier)")
    }

    func set(_ mode: AppMode, for bundleIdentifier: String) {
        lock.lock()
        modes[bundleIdentifier] = mode
        let snapshot = (modes, global)
        lock.unlock()
        save(snapshot.0, global: snapshot.1)
        JevLog.write("[allowly] \(bundleIdentifier) -> \(mode.rawValue)")
    }

    /// Forget every saved choice. The escape hatch for a "never" you regret.
    func reset() {
        lock.lock()
        modes = [:]
        global = .auto
        lock.unlock()
        save([:], global: .auto)
        JevLog.write("[allowly] saved permissions cleared")
    }

    var all: [String: AppMode] {
        lock.lock(); defer { lock.unlock() }
        return modes
    }

    private struct Stored: Codable {
        var global: GlobalMode
        var modes: [String: AppMode]
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                global = stored.global
                modes = stored.modes
                return
            }
            // Older file held a bare mode map with no global default.
            if let flat = try? JSONDecoder().decode([String: AppMode].self, from: data) {
                modes = flat
                return
            }
        }
        // Carry over anything already approved under the old flat allowlist.
        if let data = try? Data(contentsOf: Self.legacyAllowlistURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            modes = Dictionary(uniqueKeysWithValues: list.map { ($0, AppMode.always) })
            save(modes, global: global)
        }
    }

    private func save(_ snapshot: [String: AppMode], global: GlobalMode) {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(global: global, modes: snapshot)) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: url, options: .atomic)
        // 0600, because this file decides what jev does unattended.
        // Writing {"com.apple.Terminal":"always"} into a world-writable
        // copy widens what runs without asking, behind jev's own
        // Accessibility grant.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: url.path)
    }
}
