import Foundation
import JevCore

/// Where a recording of somebody's voice is allowed to go, and whose
/// credential goes with it.
///
/// Two mistakes are possible here and both are bad in a way that does not
/// show up in testing: sending the audio somewhere it was never meant to go,
/// and handing one service's key to another. Neither fails loudly. So the
/// rules are pure functions and this decides them at launch.
enum TranscriberRoutingSelfTest {

    static func run() -> [String] {
        var failures: [String] = []
        func check(_ passed: Bool, _ what: String) {
            if !passed { failures.append("transcriber: " + what) }
        }

        // ---- What counts as this machine ----
        for local in ["http://127.0.0.1:29080", "http://localhost:29080",
                      "https://127.0.0.1", "http://[::1]:29080"] {
            check(Allowly.isLoopback(URL(string: local)!), "\(local) is this machine")
        }
        for remote in ["https://generativelanguage.googleapis.com",
                       "http://127.0.0.1.evil.example", "https://evil.example",
                       "http://169.254.169.254", "https://localhost.evil.example"] {
            check(!Allowly.isLoopback(URL(string: remote)!), "\(remote) is NOT this machine")
        }
        // A scheme that is not http(s) is not a destination we understand, and
        // "file://localhost/..." must not read as local and be waved through.
        // Measured: its `.host` really is "localhost", so only the scheme
        // check stops it.
        check(!Allowly.isLoopback(URL(string: "file://localhost/etc/passwd")!),
              "a file URL is not a loopback host")

        // ---- Other spellings of this machine ----
        //
        // These all mean 127.0.0.1 to the networking stack and none of them
        // match the allowlist, so each one falls back to Google. That is the
        // safe direction, and it is pinned here because the tempting
        // "improvement" — normalise the address before comparing — would turn
        // every line below into a way to redirect a recording of somebody's
        // voice by setting one environment variable. Measured `.host` values
        // are in the comments.
        for spelling in [
            "http://2130706433",            // host = "2130706433"
            "http://0x7f000001",            // host = "0x7f000001"
            "http://017700000001",
            "http://[::ffff:127.0.0.1]",    // host = "::ffff:127.0.0.1"
            "http://localhost.",            // host = "localhost." — trailing dot
            "http://0.0.0.0",               // every interface, not this one
        ] {
            check(!Allowly.isLoopback(URL(string: spelling)!),
                  "\(spelling) is not on the allowlist — it falls back to Google, "
                  + "and normalising addresses would change that")
        }

        // Case is not one of those spellings: host names are
        // case-insensitive and `isLoopback` lowercases before comparing, so
        // this one IS local. Asserted the wrong way round first, and the
        // suite caught it — which is the only reason to write them.
        check(Allowly.isLoopback(URL(string: "http://LOCALHOST:29080")!),
              "an uppercase host name is still this machine")

        // The userinfo trick: everything before the @ is a username, so this
        // is a request to evil.example that reads like localhost.
        check(URL(string: "http://127.0.0.1@evil.example")?.host == "evil.example",
              "Foundation resolves userinfo correctly, so we can trust `.host`")
        check(!Allowly.isLoopback(URL(string: "http://127.0.0.1@evil.example")!),
              "a userinfo prefix does not make a remote host local")

        // Bracketed IPv6 is accepted, via the unbracketed arm — the reason
        // there is no "[::1]" case in `isLoopback`.
        check(URL(string: "http://[::1]:29080")?.host == "::1",
              "Foundation strips the brackets, so one arm covers both spellings")

        // ---- The override cannot widen where audio goes ----
        check(GeminiTranscriber.resolvedHost(raw: nil) == GeminiTranscriber.google,
              "unset means Google, exactly as before")
        check(GeminiTranscriber.resolvedHost(raw: "") == GeminiTranscriber.google,
              "and so does empty")
        check(GeminiTranscriber.resolvedHost(raw: "   ") == GeminiTranscriber.google,
              "and blank")
        check(GeminiTranscriber.resolvedHost(raw: "not a url at all") == GeminiTranscriber.google,
              "and nonsense")
        check(GeminiTranscriber.resolvedHost(raw: "https://evil.example") == GeminiTranscriber.google,
              "a REMOTE override is ignored — the recording does not leave for somewhere new")
        check(GeminiTranscriber.resolvedHost(raw: "http://127.0.0.1:29080")
                == URL(string: "http://127.0.0.1:29080")!,
              "a local one is honoured")
        check(GeminiTranscriber.resolvedHost(raw: "  http://localhost:29080  ")
                == URL(string: "http://localhost:29080")!,
              "and is trimmed on the way in")

        // ---- Whose key goes with it ----
        //
        // The failure this prevents: handing Google's key to whatever is
        // listening on a local port, or handing the gateway's key to Google.
        // Either one gives a working credential to somebody who should never
        // have seen it, and nothing anywhere would say so.
        check(GeminiTranscriber.keyHolder(for: GeminiTranscriber.google) == .google,
              "Google gets Google's key")
        check(GeminiTranscriber.keyHolder(for: URL(string: "http://127.0.0.1:29080")!)
                == .localGateway,
              "the local gateway gets the gateway's key")
        check(GeminiTranscriber.keyHolder(for: URL(string: "http://localhost:1")!)
                == .localGateway,
              "any local port does — it is the host that decides, not the port")
        // Unreachable today: `host` is always `resolvedHost`'s output, which
        // never yields a remote host. Kept as a backstop, and labelled as one
        // rather than dressed up as a test of the live path — if the host
        // rule is ever loosened, this is what stops the GATEWAY's key being
        // handed to whoever the new rule lets through.
        check(GeminiTranscriber.keyHolder(for: URL(string: "https://evil.example")!) == .google,
              "a remote host never gets the gateway key (backstop, not a live path)")

        // The two keys must be asked for separately, or there is only one
        // credential and the distinction above is decoration.
        check(GeminiTranscriber.KeyHolder.google != GeminiTranscriber.KeyHolder.localGateway,
              "the two holders are distinguishable")

        return failures
    }
}
