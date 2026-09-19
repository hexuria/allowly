import Foundation
import CryptoKit
import Security

/// Subscription information from the browser's PushSubscription.toJSON().
public struct PushSubscription: Codable, Sendable {
    /// The push service endpoint URL where notifications are sent.
    public let endpoint: String

    /// Server keys: p256dh and auth (both base64url).
    public let keys: Keys

    public struct Keys: Codable, Sendable {
        /// The client's P-256 public key (base64url), used for ECDH.
        public let p256dh: String
        /// The client's authentication secret (base64url).
        public let auth: String

        public init(p256dh: String, auth: String) {
            self.p256dh = p256dh
            self.auth = auth
        }
    }

    public init(endpoint: String, keys: Keys) {
        self.endpoint = endpoint
        self.keys = keys
    }
}

/// A web push notification to send.
public struct PushNotification: Sendable {
    public let title: String
    public let body: String
    /// Where the service worker should navigate when the notification is tapped.
    public let actionURL: URL?

    public init(title: String, body: String, actionURL: URL? = nil) {
        self.title = title
        self.body = body
        self.actionURL = actionURL
    }
}

/// Sends encrypted web push notifications.
///
/// Message encryption follows RFC 8291 (Message Encryption for Web Push) with
/// the aes128gcm content coding of RFC 8188; authentication follows RFC 8292
/// (VAPID). The three specs interlock, and a push service rejects — or worse,
/// accepts and the browser silently fails to decrypt — anything that deviates.
public actor PushSender {
    private let vapid: VAPID
    private let subscriberEmail: String
    private let urlSession: URLSession

    /// Record size. The body is a single record, so this only has to exceed
    /// plaintext + 1 padding byte + 16 tag bytes.
    private static let recordSize: UInt32 = 4096

    public init(vapid: VAPID, subscriberEmail: String) {
        self.vapid = vapid
        self.subscriberEmail = subscriberEmail
        self.urlSession = URLSession(configuration: .default)
    }

    /// Send a push notification to one subscriber.
    /// - Throws: `PushError`; `.subscriptionExpired` means drop the subscription.
    public func send(notification: PushNotification, to subscription: PushSubscription) async throws {
        let body = try encryptedBody(for: notification, subscription: subscription)
        try await post(body, to: subscription.endpoint)
    }

    // MARK: - Message encryption (RFC 8291 §3.4, RFC 8188 §2)

    /// Build the complete aes128gcm request body:
    ///
    ///     salt(16) ‖ rs(4, big endian) ‖ idlen(1) ‖ keyid(65) ‖ ciphertext‖tag
    ///
    /// The header block is part of the body, not a Content-Encoding parameter —
    /// that older form belongs to the superseded `aesgcm` coding. `keyid` carries
    /// our ephemeral public key, without which the browser cannot complete the
    /// key agreement and the message is undecryptable.
    func encryptedBody(for notification: PushNotification, subscription: PushSubscription) throws -> Data {
        guard let userAgentPublicKeyBytes = base64urlDecode(subscription.keys.p256dh) else {
            throw PushError.encryptionFailed("p256dh is not base64url")
        }
        guard let authSecret = base64urlDecode(subscription.keys.auth) else {
            throw PushError.encryptionFailed("auth is not base64url")
        }

        let userAgentPublicKey: P256.KeyAgreement.PublicKey
        do {
            // 65 bytes, 0x04-prefixed uncompressed point; 64-byte raw also accepted.
            userAgentPublicKey = userAgentPublicKeyBytes.count == 65
                ? try P256.KeyAgreement.PublicKey(x963Representation: userAgentPublicKeyBytes)
                : try P256.KeyAgreement.PublicKey(rawRepresentation: userAgentPublicKeyBytes)
        } catch {
            throw PushError.encryptionFailed("p256dh is not a P-256 point: \(error)")
        }

        let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        let serverPublicKey = ephemeralPrivateKey.publicKey.x963Representation   // 65 bytes
        let userAgentPublicKeyX963 = userAgentPublicKey.x963Representation       // 65 bytes

        let sharedSecret: Data
        do {
            sharedSecret = try ephemeralPrivateKey
                .sharedSecretFromKeyAgreement(with: userAgentPublicKey)
                .withUnsafeBytes { Data($0) }
        } catch {
            throw PushError.encryptionFailed("ECDH failed: \(error)")
        }

        // Stage 1: mix the shared secret with the auth secret. The info string
        // binds both public keys, so a key pair cannot be swapped underneath us.
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0x00)
        keyInfo.append(userAgentPublicKeyX963)
        keyInfo.append(serverPublicKey)
        let inputKeyingMaterial = hkdf(salt: authSecret, ikm: sharedSecret, info: keyInfo, length: 32)

        // Stage 2: the record salt derives the content key and nonce.
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else {
            throw PushError.encryptionFailed("could not generate a random salt")
        }

        let contentEncryptionKey = hkdf(
            salt: salt, ikm: inputKeyingMaterial,
            info: Data("Content-Encoding: aes128gcm\u{00}".utf8), length: 16)
        let nonceBytes = hkdf(
            salt: salt, ikm: inputKeyingMaterial,
            info: Data("Content-Encoding: nonce\u{00}".utf8), length: 12)

        // The record's plaintext ends with a delimiter: 0x02 for the last record.
        var plaintext = try JSONEncoder().encode(NotificationPayload(notification))
        plaintext.append(0x02)

        guard plaintext.count + 16 <= Int(Self.recordSize) else {
            throw PushError.encryptionFailed("notification exceeds one record")
        }

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext,
                                      using: SymmetricKey(data: contentEncryptionKey),
                                      nonce: try AES.GCM.Nonce(data: nonceBytes))
        } catch {
            throw PushError.encryptionFailed("AES-GCM seal failed: \(error)")
        }

        var body = salt
        body.append(contentsOf: withUnsafeBytes(of: Self.recordSize.bigEndian) { Data($0) })
        body.append(UInt8(serverPublicKey.count))
        body.append(serverPublicKey)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)          // the tag is authentication data, not optional
        return body
    }

    /// HKDF-SHA256: extract then expand. Only lengths ≤ 32 are needed here, so
    /// expansion is a single block.
    private func hkdf(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
        let pseudoRandomKey = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        var block = info
        block.append(0x01)
        let output = HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: Data(pseudoRandomKey)))
        return Data(output).prefix(length)
    }

    // MARK: - Delivery (RFC 8030, RFC 8292)

    private func post(_ body: Data, to endpoint: String) async throws {
        guard let url = URL(string: endpoint),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else {
            throw PushError.invalidEndpoint("subscription endpoint is not a usable URL")
        }

        let jwt = try vapid.createJWT(subscriber: subscriberEmail, audience: "\(scheme)://\(host)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // No parameters: the salt and record size live in the body's header block.
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("vapid t=\(jwt), k=\(vapid.publicKeyBase64URL)", forHTTPHeaderField: "Authorization")
        request.setValue("3600", forHTTPHeaderField: "TTL")
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushError.sendFailed("no HTTP response from the push service")
        }

        switch http.statusCode {
        case 200...299:
            return
        case 404, 410:
            throw PushError.subscriptionExpired("endpoint returned \(http.statusCode)")
        case 429:
            throw PushError.rateLimited("push service rate limit exceeded")
        default:
            let text = String(data: data, encoding: .utf8) ?? "(binary)"
            throw PushError.sendFailed("HTTP \(http.statusCode): \(text)")
        }
    }
}

// MARK: - Payload

/// What the service worker receives in `event.data.json()`.
private struct NotificationPayload: Encodable {
    let title: String
    let body: String
    let url: String?
    let tag: String
    let requireInteraction: Bool

    init(_ notification: PushNotification) {
        self.title = notification.title
        self.body = notification.body
        self.url = notification.actionURL?.absoluteString
        // One approval replaces the last rather than stacking up on the lock screen.
        self.tag = "jev-approval"
        self.requireInteraction = true
    }
}

// MARK: - Errors

public enum PushError: Error, CustomStringConvertible {
    case encryptionFailed(String)
    case invalidEndpoint(String)
    case sendFailed(String)
    case subscriptionExpired(String)
    case rateLimited(String)

    public var description: String {
        switch self {
        case .encryptionFailed(let message): return "Encryption failed: \(message)"
        case .invalidEndpoint(let message): return "Invalid endpoint: \(message)"
        case .sendFailed(let message): return "Send failed: \(message)"
        case .subscriptionExpired(let message): return "Subscription expired: \(message)"
        case .rateLimited(let message): return "Rate limited: \(message)"
        }
    }
}

// MARK: - Base64URL

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    return Data(base64Encoded: base64)
}
