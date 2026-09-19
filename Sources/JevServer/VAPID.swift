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

        if FileManager.default.fileExists(atPath: keyPath.path) {
            let keyData = try Data(contentsOf: keyPath)
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyData)
            return VAPID(privateKey: privateKey)
        } else {
            let privateKey = P256.Signing.PrivateKey()
            if !FileManager.default.fileExists(atPath: storageURL.path) {
                try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            }
            try privateKey.rawRepresentation.write(to: keyPath)
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
