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
        check(!Allowly.isLoopback(URL(string: "file://localhost/etc/passwd")!),
              "a file URL is not a loopback host")

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
        check(GeminiTranscriber.keyHolder(for: URL(string: "https://evil.example")!) == .google,
              "and anything else is treated as Google, which is the only key it could "
              + "already have had — resolvedHost never yields such a host anyway")

        // The two keys must be asked for separately, or there is only one
        // credential and the distinction above is decoration.
        check(GeminiTranscriber.KeyHolder.google != GeminiTranscriber.KeyHolder.localGateway,
              "the two holders are distinguishable")

        return failures
    }
}
