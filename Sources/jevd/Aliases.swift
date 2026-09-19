import Foundation

/// Spoken names for apps whose real names do not survive a microphone.
///
/// "Waz" is transcribed as "was", "show waz" as "show us". No matching
/// strategy recovers that reliably, so let the word be chosen instead: say
/// "terminal" and mean Waz.
final class Aliases: @unchecked Sendable {
    static let shared = Aliases()

    private let lock = NSLock()
    private var map: [String: String] = [:]   // spoken name -> bundle id

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/aliases.json")
    }

    init() { load() }

    func bundleId(for spoken: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[spoken.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    func set(_ spoken: String, to bundleId: String) {
        lock.lock()
        map[spoken.lowercased()] = bundleId
        let snapshot = map
        lock.unlock()
        save(snapshot)
        JevLog.write("[jev] alias “\(spoken)” -> \(bundleId)")
    }

    var all: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            map = stored
        }
    }

    private func save(_ snapshot: [String: String]) {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
