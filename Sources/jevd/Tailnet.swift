import Foundation

/// Where the phone should point itself.
///
/// The pairing dialog used to show a hardcoded `https://<ip>/pair`, which was
/// wrong in every part: raw IP instead of the MagicDNS name, a path that is not
/// a route, no port, and no token. Everything here is read from the live
/// Tailscale state instead.
enum Tailnet {
    /// The machine's MagicDNS name, e.g. your-mac.your-tailnet.ts.net
    static func deviceName() -> String? {
        guard let json = runTailscale(["status", "--json"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = root["Self"] as? [String: Any],
              let dnsName = selfNode["DNSName"] as? String,
              !dnsName.isEmpty else { return nil }
        // Tailscale reports a fully-qualified name with a trailing dot.
        return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    }

    /// True when `tailscale serve` is fronting us with TLS on 443.
    static func serveIsActive() -> Bool {
        guard let status = runTailscale(["serve", "status"]) else { return false }
        return status.contains("https://") && status.contains("proxy")
    }

    /// The URL to hand the phone, with the token embedded.
    ///
    /// Prefers the HTTPS MagicDNS origin, because the PWA needs a secure context
    /// for the microphone, service worker and push. Falls back to the plain
    /// tailnet address only when serve is not running, and that fallback cannot
    /// do voice or notifications.
    static func pairingURL(token: String, localPort: UInt16) -> String {
        if let name = deviceName(), serveIsActive() {
            return "https://\(name)/?token=\(token)"
        }
        if let name = deviceName() {
            return "http://\(name):\(localPort)/?token=\(token)"
        }
        let host = JevRuntime.tailnetAddress() ?? "127.0.0.1"
        return "http://\(host):\(localPort)/?token=\(token)"
    }

    /// The same link with the token taken out, for saying out loud.
    ///
    /// `pairingURL` carries the bearer token for full remote control of
    /// this Mac, and it was being written to `jev.log` on every launch —
    /// a file nothing rotates, in the file the README tells you to tail
    /// when something goes wrong. `publicURL` already refuses to put a
    /// token in a notification for exactly this reason; the log is not a
    /// lesser place for a credential to sit.
    static func loggableURL(token: String, localPort: UInt16) -> String {
        let full = pairingURL(token: token, localPort: localPort)
        // Fails CLOSED. Returning the full URL when the marker is missing
        // is the wrong default for a function whose whole job is removing
        // a credential — one change to `pairingURL`'s shape and the token
        // is back in the log with nothing to notice it.
        guard let cut = full.range(of: "?token=") else {
            return full.contains(token) ? "<the pairing link>" : full
        }
        return String(full[..<cut.lowerBound]) + "?token=<in the menu bar>"
    }

    /// Where a notification should send the phone: the same origin it paired
    /// with, minus the token — that already lives in the PWA's storage, and a
    /// token in a notification URL is a token in the notification history.
    ///
    /// Cached: this is called on every escalation and the underlying lookup
    /// spawns the tailscale binary.
    static func publicURL(path: String) -> URL? {
        // Cached, but not forever. `tailscale serve` can be restarted
        // and a device can be renamed, and a permanently cached origin
        // meant every notification afterwards pointed at a host that no
        // longer answers — until jevd itself was restarted. Five
        // minutes is short enough that a rename fixes itself over a
        // coffee, and long enough that a burst of escalations does not
        // spawn the tailscale binary once each.
        cacheLock.lock()
        let cached = cachedOrigin
        let age = cachedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        cacheLock.unlock()

        if let cached, age < 300 { return URL(string: cached + path) }
        guard let name = deviceName(), serveIsActive() else {
            // Keep serving the last known origin rather than dropping
            // the notification entirely when the lookup fails once.
            return cached.flatMap { URL(string: $0 + path) }
        }
        let origin = "https://\(name)"
        cacheLock.lock()
        cachedOrigin = origin
        cachedAt = Date()
        cacheLock.unlock()
        return URL(string: origin + path)
    }

    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var cachedOrigin: String?
    private static let cacheLock = NSLock()

    /// A short label for the menu bar.
    static func displayName() -> String {
        deviceName() ?? JevRuntime.tailnetAddress() ?? "not on a tailnet"
    }

    private static func runTailscale(_ arguments: [String]) -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
