import Foundation
import CryptoKit

/// VAPID (RFC 8292) key management and JWT generation.
/// Handles P-256 keypair generation/persistence and ES256 signed token creation.
public struct VAPID {
    private let privateKey: P256.Signing.PrivateKey
    public let publicKeyBase64URL: String

    /// Initialize VAPID with a private key.
    /// - Parameter privateKey: The P-256 signing key.
    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        // Must be the 65-byte uncompressed point (0x04 ‖ X ‖ Y). CryptoKit's
        // rawRepresentation omits the 0x04 prefix, and both the browser's
        // applicationServerKey and the VAPID `k=` parameter reject 64 bytes.
        self.publicKeyBase64URL = base64url(privateKey.publicKey.x963Representation)
    }

    /// Load VAPID from a stored private key bytes, or generate new if not found.
    /// - Parameter storageURL: Path where private key is persisted.
    /// - Returns: VAPID instance.
    public static func loadOrGenerate(storageURL: URL) throws -> VAPID {
        let keyPath = storageURL.appendingPathComponent("vapid-private.key")

        if FileManager.default.fileExists(atPath: keyPath.path),
           let keyData = try? Data(contentsOf: keyPath),
           let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            return VAPID(privateKey: privateKey)
        } else {
            // A key file that exists but does not parse used to throw,
            // and `PushStore.init` swallowed it with `try?` — so a
            // truncated or empty file (this write is not atomic; a crash
            // or a full disk during the first one produces exactly that)
            // left `vapid == nil` for the life of the process, and
            // `notify` returned without logging anything or recording a
            // failure. Measured: 12 zero bytes, or an empty file, and
            // push is dead forever with no trace anywhere.
            //
            // Regenerating invalidates the subscriptions signed with the
            // old key, which sounds worse than it is: with an unreadable
            // key nothing could be sent to them anyway. The phone
            // re-subscribes on its next visit.
            if FileManager.default.fileExists(atPath: keyPath.path) {
                try? FileManager.default.removeItem(at: keyPath)
            }
            let privateKey = P256.Signing.PrivateKey()
            if !FileManager.default.fileExists(atPath: storageURL.path) {
                try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            }
            // Born 0600. Written-then-chmodded leaves a window in
            // which the push signing identity is world-readable.
            FileManager.default.createFile(atPath: keyPath.path,
                                           contents: privateKey.rawRepresentation,
                                           attributes: [.posixPermissions: 0o600])
            // 0600. This is the identity every notification jev sends is
            // signed with; at 0644 any local process could sign one the
            // paired phone renders as jev's, carrying a link straight to
            // the approval screen.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: keyPath.path)
            return VAPID(privateKey: privateKey)
        }
    }

    /// Create a VAPID JWT for push authentication.
    /// - Parameters:
    ///   - subscriber: The subscriber email (subject claim, format: mailto:user@example.com).
    ///   - audience: The push service audience (typically the origin of the subscription endpoint URL).
    ///   - expirationInterval: How long the JWT is valid (default 12 hours).
    /// - Returns: A signed JWT string.
    public func createJWT(
        subscriber: String,
        audience: String,
        expirationInterval: TimeInterval = 12 * 3600
    ) throws -> String {
        let now = Date()
        let exp = Int(now.timeIntervalSince1970) + Int(expirationInterval)

        let payload = VAPIDPayload(
            aud: audience,
            exp: exp,
            sub: subscriber
        )

        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(payload)
        let payloadBase64URL = base64url(payloadData)

        let headerData = try encoder.encode(["alg": "ES256", "typ": "JWT"])
        let headerBase64URL = base64url(headerData)

        let signatureInput = "\(headerBase64URL).\(payloadBase64URL)".data(using: .utf8)!

        let signature = try privateKey.signature(for: signatureInput)
        let signatureBase64URL = base64url(signature.rawRepresentation)

        return "\(headerBase64URL).\(payloadBase64URL).\(signatureBase64URL)"
    }

    /// The application server key, as the 65-byte uncompressed point.
    public var publicKeyBytes: Data {
        privateKey.publicKey.x963Representation
    }
}

private struct VAPIDPayload: Encodable {
    let aud: String
    let exp: Int
    let sub: String
}


enum VAPIDError: Error {
    case invalidPath
    case jwtCreationFailed
}

/// Who the push service should contact about this sender.
///
/// The VAPID `sub` claim, and the reason no notification jev has ever
/// sent has arrived. It was hardcoded to `mailto:jev@localhost`, and
/// `web.push.apple.com` rejects that JWT outright — **403
/// `BadJwtToken`**, before it looks at the endpoint, the keys or the
/// payload. Measured against the real endpoint with everything else
/// held identical and a deliberately invalid device token, so nothing
/// could be delivered either way:
///
///     mailto:jev@localhost      -> 403 {"reason":"BadJwtToken"}
///     mailto:jev@example.com    -> 400 {"reason":"BadWebPushToken"}
///     https://github.com/jev    -> 400 {"reason":"BadWebPushToken"}
///
/// A 400 there means the JWT was accepted and only the fake token was
/// refused. The 403 flips on that one string. FCM and Mozilla accept
/// `@localhost`, which is why this survived: it is broken precisely for
/// the iOS/Safari PWA jev is built around, and it failed behind a
/// single log line that nothing read.
public enum VAPIDSubject {
    /// A placeholder Apple accepts, because the daemon has to work
    /// before anyone configures anything. Set `JEV_VAPID_SUBJECT` to a
    /// real contact — a `mailto:` you read or an `https://` page about
    /// your deployment — if you would rather a push service could
    /// reach you about it.
    public static let fallback = "mailto:jev@example.com"

    /// Env first, then a file, then the fallback.
    ///
    /// The file is not optional extra credit. The documented install is
    /// `make app` and launching `Jev.app` from Finder, which inherits no
    /// shell — this repo already learned that once, which is why the
    /// API key has exactly this pair of sources. An environment
    /// variable as the ONLY way out of a dead-push state is no way out
    /// at all, and the log line that names it would have been telling
    /// people to do something that could not work.
    public static var configured: String {
        if let fromEnv = ProcessInfo.processInfo.environment["JEV_VAPID_SUBJECT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnv.isEmpty {
            return isAcceptable(fromEnv) ? fromEnv : fallback
        }
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return isAcceptable(trimmed) ? trimmed : fallback }
        }
        return fallback
    }

    /// `~/Library/Application Support/jev/vapid-subject`
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/vapid-subject")
    }

    /// Would a push service take this as a contact?
    ///
    /// Deliberately a shape test, not a guess at any one service's
    /// rules: a scheme it recognises, and a host that is a real
    /// domain — not `localhost`, not a bare hostname, not an address
    /// literal. That is exactly the check that would have caught the
    /// value this project shipped with.
    public static func isAcceptable(_ subject: String) -> Bool {
        let lowered = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A contact with a space or a newline in it is not a contact,
        // and a push service is entitled to 403 the whole JWT over it —
        // which would put you straight back in the dead-push state with
        // an override that looks applied.
        guard !lowered.isEmpty,
              !lowered.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { s in s.value < 0x20 } })
        else { return false }
        let host: Substring
        if lowered.hasPrefix("mailto:") {
            let address = lowered.dropFirst("mailto:".count)
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return false }
            host = parts[1]
        } else if lowered.hasPrefix("https://") {
            let rest = lowered.dropFirst("https://".count)
            host = rest.split(separator: "/", maxSplits: 1).first ?? ""
        } else {
            return false
        }
        // A query string is not part of the host.
        let bare = host.split(separator: "?", maxSplits: 1).first ?? host
        guard bare.contains("."), !bare.hasPrefix("."), !bare.hasSuffix(".") else { return false }
        // An address literal is not a contact, and `localhost.localdomain`
        // is the same mistake wearing a dot. By LABEL, not by prefix:
        // `localhosting.com` and `localhost.example.com` are real hosts
        // and were both being refused, then silently replaced by the
        // fallback.
        let labels = bare.split(separator: ".")
        guard labels.first != "localhost", labels.count >= 2,
              bare.rangeOfCharacter(from: .letters) != nil else { return false }
        return true
    }
}
