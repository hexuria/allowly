import Foundation
import JevCore

/// Apps the user has said "always allow" to, remembered across restarts.
///
/// This is how the allowlist gets built: by answering prompts, not by
/// enumerating 377 apps up front and hoping the list stays current.
final class UserAllowlist: @unchecked Sendable {
    static let shared = UserAllowlist()

    private let lock = NSLock()
    private var identifiers: Set<String> = []

    private static var fileURL: URL {
        Allowly.supportDirectory.appendingPathComponent("allowlist.json")
    }

    init() { load() }

    func contains(_ bundleIdentifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifiers.contains(bundleIdentifier)
    }

    func add(_ bundleIdentifier: String) {
        lock.lock()
        identifiers.insert(bundleIdentifier)
        let snapshot = identifiers
        lock.unlock()
        save(snapshot)
        JevLog.write("[allowly] always-allow added: \(bundleIdentifier)")
    }

    var all: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return identifiers
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        identifiers = Set(list)
    }

    private func save(_ snapshot: Set<String>) {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(snapshot).sorted()) else { return }
        // Born 0600, like everything else jev keeps. This one
        // was tightened only by the next launch's sweep, so it
        // sat readable for the whole session it was made in.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: url, options: .atomic)
    }
}
