import Foundation

/// Finding the DevTools endpoint of the browser the person is actually signed
/// into.
///
/// This is harder than it looks, and the reason is worth writing down, because
/// the obvious approach stopped working and left no error behind.
///
/// Chrome 136 stopped honouring `--remote-debugging-port` and
/// `--remote-debugging-pipe` when the profile is the default one. It is a
/// deliberate anti-infostealer measure: a non-default `--user-data-dir` gets a
/// different encryption key, so malware that attaches over CDP cannot decrypt
/// the real profile's cookies. The flag is not rejected — it is ignored, so the
/// classic failure is an automation client that connects to nothing and hangs.
/// Chrome's own words, from the shipped binary:
///
///     DevTools remote debugging requires a non-default data directory.
///     Specify this using --user-data-dir.
///
/// That would be the end of driving someone's signed-in browser, except Chrome
/// 144 added a replacement that is better than the flag ever was: a per-browser
/// opt-in at `chrome://inspect/#remote-debugging`, "Allow remote debugging for
/// this browser instance". It is consent the person gives in their own browser,
/// it is recorded in their profile, and jev never turns it on for them.
///
/// Chrome 147 then closed the last discovery hole: `/json/*` no longer answers
/// on the default profile. Reading the endpoint therefore requires reading a
/// file inside the profile directory, which is itself the proof that the caller
/// is already running as the person who owns the browser.
///
/// The consequence for jev: discovery is a file read, not a network probe, and
/// the thing it reads is a credential. See `Endpoint.webSocketURL`.
public enum ChromeDiscovery {

    /// A live DevTools endpoint.
    ///
    /// `webSocketURL` embeds a per-launch UUID that is the whole authentication
    /// story for CDP: anyone holding it has full control of a signed-in
    /// browser. It is therefore never logged, never journalled, never put in a
    /// failure reason and never sent to a model. `description` exists so a
    /// human-readable mention of the endpoint cannot accidentally carry it.
    public struct Endpoint: Sendable, CustomStringConvertible {
        public let port: Int
        public let webSocketURL: URL
        public let profileDirectory: URL

        public var description: String { "Chrome DevTools on 127.0.0.1:\(port)" }
    }

    /// Where Chrome and its close relatives keep a profile on macOS.
    ///
    /// Ordered: the plain Chrome profile is overwhelmingly the common case, and
    /// checking it first means the usual path does one `stat`.
    static let profileDirectories: [String] = [
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Google/Chrome Beta",
        "Library/Application Support/Google/Chrome Dev",
        "Library/Application Support/Google/Chrome Canary",
        "Library/Application Support/Chromium",
    ]

    // MARK: - DevToolsActivePort

    /// What Chrome writes into `DevToolsActivePort` when a port is live.
    ///
    /// Two lines: the port, then the browser's WebSocket path. Both are
    /// required. A one-line file means Chrome wrote the port but not the path,
    /// and guessing the path produces a URL that 404s on the upgrade — so this
    /// returns nil rather than something that looks usable and is not.
    ///
    /// Pure, and takes the file's text rather than reading it, so the parser
    /// can be tested without a browser or a profile on disk.
    public static func parseActivePort(_ contents: String) -> (port: Int, path: String)? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }

        guard let port = Int(lines[0].trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return nil }

        let path = lines[1].trimmingCharacters(in: .whitespaces)
        // Chrome writes "/devtools/browser/<uuid>". Requiring the prefix keeps a
        // stale or truncated file from becoming a request to an arbitrary path.
        guard path.hasPrefix("/devtools/browser/"), path.count > "/devtools/browser/".count else {
            return nil
        }
        return (port, path)
    }

    // MARK: - The chrome://inspect toggle

    /// Whether the person has ticked "Allow remote debugging for this browser
    /// instance", as recorded in the profile's `Local State`.
    ///
    /// Three answers, and the third one matters: `nil` means no profile records
    /// the setting either way, which is what a Chrome that has never shown the
    /// page looks like. Telling someone to untick something they never ticked
    /// is a worse error message than saying nothing.
    ///
    /// Pure, for the same reason as `parseActivePort`.
    public static func toggleState(localState contents: String) -> Bool? {
        guard let data = contents.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devtools = root["devtools"] as? [String: Any],
              let remote = devtools["remote_debugging"] as? [String: Any]
        else { return nil }
        return remote["user-enabled"] as? Bool
    }

    /// The authoritative WebSocket URL, from a `/json/version` body.
    ///
    /// Pure, so the JSON handling is testable without a browser.
    public static func parseVersionPayload(_ data: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["webSocketDebuggerUrl"] as? String,
              let url = URL(string: text),
              url.scheme == "ws" || url.scheme == "wss"
        else { return nil }
        // Only ever our own loopback browser. A payload naming another host is
        // not something to connect to just because Chrome said it.
        guard url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        return url
    }

    // MARK: - Lookup

    /// What a lookup found. Distinguishing these is the whole point: each one
    /// needs a different sentence on someone's phone, and the wrong sentence
    /// ("restart Chrome") sends them off to lose their tabs for no reason.
    public enum Lookup: Sendable {
        case found(Endpoint)
        /// Chrome answered, but the per-session "Allow remote debugging"
        /// prompt has not been accepted yet. Nothing to fix but a tap.
        case consentPending
        /// A profile exists and records the toggle as off.
        case toggleOff
        /// A profile exists and has never recorded the toggle either way.
        case neverEnabled
        /// The toggle is on but no port is live — genuinely wants a restart.
        case notListening
        case noProfile
    }

    /// Find the live endpoint.
    ///
    /// Deliberately does not launch Chrome, restart it, or change any setting.
    /// If remote debugging is off, that is the person's choice to reverse in
    /// their own browser; `explain` says how.
    public static func lookup(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> Lookup {
        var sawProfile = false
        var explicitlyOff = false
        var sawToggleOn = false

        for relative in profileDirectories {
            let profile = home.appendingPathComponent(relative)

            if let state = try? String(contentsOf: profile.appendingPathComponent("Local State"),
                                       encoding: .utf8) {
                sawProfile = true
                switch toggleState(localState: state) {
                case .some(true): sawToggleOn = true
                case .some(false): explicitlyOff = true
                case .none: break
                }
            }

            guard let contents = try? String(contentsOf: profile.appendingPathComponent("DevToolsActivePort"),
                                             encoding: .utf8),
                  let (port, path) = parseActivePort(contents)
            else { continue }

            switch await probe(port: port) {
            case .refused:
                // A closed browser leaves the file behind, so a parseable file
                // is not evidence that anything is listening.
                continue

            case .consentPending:
                return .consentPending

            case .version(let data):
                // Prefer what the browser says over what the file says. Chrome
                // leaves the file behind when it is next launched on the same
                // port with a different --user-data-dir, and the stale id in it
                // produces a URL that passes every check here and then 404s on
                // the upgrade.
                if let url = parseVersionPayload(data) {
                    return .found(Endpoint(port: port, webSocketURL: url, profileDirectory: profile))
                }
                fallthrough

            case .discoveryDisabled:
                // Chrome 147+ stops answering /json/* on the default profile.
                // The path Chrome wrote to DevToolsActivePort still works, and
                // reading that file is itself proof of being the profile's owner.
                if let url = URL(string: "ws://127.0.0.1:\(port)\(path)") {
                    return .found(Endpoint(port: port, webSocketURL: url, profileDirectory: profile))
                }
                continue
            }
        }

        if sawToggleOn { return .notListening }
        if explicitlyOff { return .toggleOff }
        if sawProfile { return .neverEnabled }
        return .noProfile
    }

    /// Why there is no endpoint, in words that name the next action.
    ///
    /// Never includes the WebSocket path: this string reaches a card on
    /// someone's phone and goes through the journal on the way.
    public static func explain(_ lookup: Lookup) -> String {
        switch lookup {
        case .found:
            return "Chrome is reachable."
        case .consentPending:
            return "Chrome is asking whether to allow remote debugging — accept the prompt in Chrome, then try again."
        case .toggleOff:
            return "Remote debugging is turned off. Turn it on at chrome://inspect/#remote-debugging."
        case .neverEnabled:
            return "Chrome has not been told to allow remote debugging. Tick "
                + "\"Allow remote debugging for this browser instance\" at chrome://inspect/#remote-debugging."
        case .notListening:
            return "Chrome allows remote debugging but no port is listening — restart Chrome."
        case .noProfile:
            return "No Chrome profile found — is Chrome installed?"
        }
    }

    // MARK: -

    enum Probe {
        case version(Data)
        /// 404: Chrome 147+ on a default profile.
        case discoveryDisabled
        /// 403: the per-session consent prompt has not been accepted.
        case consentPending
        case refused
    }

    /// Ask the browser about itself. Loopback only, and short: this runs on the
    /// way to every web task, so it must never be the slow part.
    static func probe(port: Int) async -> Probe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return .refused }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return .refused }

        switch http.statusCode {
        case 200: return .version(data)
        case 403: return .consentPending
        default: return .discoveryDisabled
        }
    }

}
