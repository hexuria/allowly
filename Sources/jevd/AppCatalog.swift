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
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingRefresh: DispatchWorkItem?
    private(set) var lastRefreshed = Date.distantPast

    static let roots = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Scan the usual application directories. Cheap enough to run at launch
    /// — and, since `watch()`, whenever one of them changes. It used to run
    /// exactly once, so an app installed after launch could not be named
    /// until jev was restarted, and a deleted one stayed offerable.
    func refresh() {
        var found: [String: Entry] = [:]
        let roots = Self.roots

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
        lastRefreshed = Date()
        lock.unlock()
    }

    /// Rescan when an application folder changes, rather than at every
    /// command or never.
    ///
    /// The global scope is "everything that could be named": installed,
    /// running, visible. Scanning it per command would be the slow way to be
    /// current; scanning it once would be the stale way. The folders are
    /// watched instead, and a change — an install, a delete, a drag to the
    /// Trash — schedules one rescan after a short quiet period, so a copy
    /// that writes a hundred files costs one scan rather than a hundred.
    func watch() {
        lock.lock(); defer { lock.unlock() }
        guard watchers.isEmpty else { return }
        for root in Self.roots {
            let descriptor = open(root, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in self?.scheduleRefresh(because: root) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleRefresh(because root: String) {
        lock.lock()
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = self.all.count
            self.refresh()
            let after = self.all.count
            JevLog.write("[jev] apps: \(root) changed; catalog \(before) → \(after)")
        }
        pendingRefresh = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
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
