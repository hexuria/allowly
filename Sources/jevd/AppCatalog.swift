import Foundation
import AppKit

/// Every application actually installed on this Mac, discovered at runtime.
///
/// The previous project hardcoded six app names in Rust, which meant the system
/// could only ever act on six apps and went stale the moment anything was
/// installed. This asks the machine instead.
final class AppCatalog: @unchecked Sendable {
    struct Entry: Sendable {
        let name: String
        let bundleIdentifier: String
    }

    static let shared = AppCatalog()

    private let lock = NSLock()
    private var entries: [Entry] = []

    /// Scan the usual application directories. Cheap enough to run at launch.
    func refresh() {
        var found: [String: Entry] = [:]
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]

        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = root + "/" + item
                guard let bundle = Bundle(path: path),
                      let identifier = bundle.bundleIdentifier else { continue }
                let name = (item as NSString).deletingPathExtension
                found[identifier] = Entry(name: name, bundleIdentifier: identifier)
            }
        }

        lock.lock()
        entries = Array(found.values).sorted { $0.name < $1.name }
        lock.unlock()
    }

    var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var allBundleIdentifiers: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.map(\.bundleIdentifier))
    }

    /// Resolve a spoken app name to a bundle id.
    ///
    /// Speech gives us "Google Chrome", "chrome", or "Chrome." with a full stop,
    /// so match progressively rather than demanding an exact string.
    func resolve(spokenName raw: String) -> Entry? {
        let needle = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            .lowercased()
        guard !needle.isEmpty else { return nil }

        let candidates = all

        // A user-chosen word wins over everything: it exists precisely because
        // the real name does not transcribe.
        if let bundleId = Aliases.shared.bundleId(for: needle),
           let entry = candidates.first(where: { $0.bundleIdentifier == bundleId }) {
            return entry
        }

        if let exact = candidates.first(where: { $0.name.lowercased() == needle }) { return exact }

        // The loose tiers refuse rather than pick, when more than one app
        // fits. `first(where:)` handed back whichever sorted first by
        // display name — so with both "Code" and "Code - Insiders"
        // installed, "quit code" silently chose one of them. An alias is
        // the answer to a genuine tie, and saying so beats guessing.
        func only(_ matching: (Entry) -> Bool) -> Entry? {
            let hits = candidates.filter(matching)
            return hits.count == 1 ? hits[0] : nil
        }
        if let prefixed = only({ $0.name.lowercased().hasPrefix(needle) }) { return prefixed }
        if let contained = only({ $0.name.lowercased().contains(needle) }) { return contained }
        // "google chrome" said as "chrome": try the last word of each app name.
        if let word = only({ entry in
            entry.name.lowercased().split(separator: " ").contains(Substring(needle))
        }) { return word }

        // Last resort: closest name by edit distance. Speech turns "Waz" into
        // "was" or "wax", which no prefix or substring rule will ever match.
        // Only accept a near miss on short names, where one wrong letter is
        // plausible; on long names it would match far too eagerly.
        let scored = candidates.compactMap { entry -> (Entry, Int)? in
            let name = entry.name.lowercased()
            guard abs(name.count - needle.count) <= 2 else { return nil }
            let distance = Self.editDistance(name, needle)
            let budget = name.count <= 5 ? 1 : 2
            return distance <= budget ? (entry, distance) : nil
        }
        return scored.min { $0.1 < $1.1 }?.0
    }

    /// Plain Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
