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

    /// Where a notification should send the phone: the same origin it paired
    /// with, minus the token — that already lives in the PWA's storage, and a
    /// token in a notification URL is a token in the notification history.
    ///
    /// Cached: this is called on every escalation and the underlying lookup
    /// spawns the tailscale binary.
    static func publicURL(path: String) -> URL? {
        cacheLock.lock()
        let cached = cachedOrigin
        cacheLock.unlock()

        if let cached { return URL(string: cached + path) }
        guard let name = deviceName(), serveIsActive() else { return nil }
        let origin = "https://\(name)"
        cacheLock.lock()
        cachedOrigin = origin
        cacheLock.unlock()
        return URL(string: origin + path)
    }

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
