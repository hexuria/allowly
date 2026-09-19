import Foundation
import AppKit

/// What is actually on screen inside a browser.
///
/// The frontmost *application* is not enough to know what a command means.
/// "mute" in Chrome means one thing on YouTube and something else on a page
/// with no video at all, so the address is part of the context.
///
/// Reading it goes through Apple Events, which macOS gates behind an
/// Automation permission per target app. The first read raises that prompt —
/// which jev itself will surface on your phone.
enum BrowserContext {
    /// Scripting names, keyed by bundle id. Only browsers that expose their
    /// address through Apple Events are listed; the rest simply have no host.
    private static let scriptable: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.apple.Safari": "Safari",
    ]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (host: String?, at: Date, bundleId: String)?
    /// Long enough that a burst of commands costs one Apple Event, short
    /// enough that switching tabs is picked up before you notice.
    private static let freshness: TimeInterval = 1.5

    /// The host of the frontmost browser tab, lowercased and without "www.".
    /// Nil when the frontmost app is not a scriptable browser.
    static func currentHost() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let bundleId = app?.bundleIdentifier, let name = scriptable[bundleId] else { return nil }

        lock.lock()
        if let cached, cached.bundleId == bundleId, Date().timeIntervalSince(cached.at) < freshness {
            let host = cached.host
            lock.unlock()
            return host
        }
        lock.unlock()

        let host = readHost(appName: name)
        lock.lock()
        let changed = cached?.host != host || cached?.bundleId != bundleId
        cached = (host, Date(), bundleId)
        lock.unlock()
        if changed {
            // Worth one line: a nil here means page-level scoping is silently
            // off, almost always because the Automation permission for this
            // browser has not been granted yet.
            JevLog.write("[jev] page: \(host ?? "no address from \(name) — grant Automation for it")")
        }
        return host
    }

    private static func readHost(appName: String) -> String? {
        let script = appName == "Safari"
            ? "tell application \"Safari\" to get URL of front document"
            : "tell application \"\(appName)\" to get URL of active tab of front window"

        // argv, never a shell string: the app name is ours but the habit is
        // what keeps an injected one from ever mattering.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
}
