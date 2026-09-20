import Foundation
import CryptoKit

/// Proves the push crypto against the spec without a push service.
///
/// The previous self-test asserted the shape of a header the implementation
/// happened to produce, so it passed while nothing could ever be decrypted.
/// This one plays the browser: it performs the receiver half of RFC 8291 on a
/// real encrypted body and fails if the plaintext does not come back.
public func webPushSelfTest() async -> [String] {
    var failures: [String] = []
    failures.append(contentsOf: await testMessageRoundTrip())
    failures.append(contentsOf: testVAPIDSignature())
    failures.append(contentsOf: testBase64URL())
    return failures
}

private func testMessageRoundTrip() async -> [String] {
    var failures: [String] = []

    // Stand in for the browser: its key agreement pair and auth secret.
    let userAgentKey = P256.KeyAgreement.PrivateKey()
    var authSecret = Data(count: 16)
    _ = authSecret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

    let subscription = PushSubscription(
        endpoint: "https://push.example.com/send/abc",
        keys: .init(p256dh: base64url(userAgentKey.publicKey.x963Representation),
                    auth: base64url(authSecret)))

    let vapid = VAPID(privateKey: P256.Signing.PrivateKey())
    let sender = PushSender(vapid: vapid, subscriberEmail: VAPIDSubject.configured)
    let notification = PushNotification(title: "Needs you",
                                        body: "Terminal wants Full Disk Access",
                                        actionURL: URL(string: "https://example.test/?id=42"))

    let body: Data
    do {
        body = try await sender.encryptedBody(for: notification, subscription: subscription)
    } catch {
        return ["push: encryption threw \(error)"]
    }

    // Receiver side. Header: salt(16) ‖ rs(4) ‖ idlen(1) ‖ keyid(idlen).
    guard body.count > 21 else { return ["push: body too short (\(body.count) bytes)"] }
    let bytes = [UInt8](body)
    let salt = Data(bytes[0..<16])
    let recordSize = bytes[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let keyIDLength = Int(bytes[20])
    guard keyIDLength == 65 else { return ["push: keyid should be a 65-byte point, got \(keyIDLength)"] }
    guard body.count >= 21 + keyIDLength + 16 else { return ["push: body shorter than header + tag"] }
    if recordSize < UInt32(body.count - 21 - keyIDLength) {
        failures.append("push: record size \(recordSize) smaller than the record it describes")
    }

    let serverPublicKeyBytes = Data(bytes[21..<(21 + keyIDLength)])
    let sealedBytes = Data(bytes[(21 + keyIDLength)...])

    do {
        let serverPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPublicKeyBytes)
        let shared = try userAgentKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
            .withUnsafeBytes { Data($0) }

        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0x00)
        keyInfo.append(userAgentKey.publicKey.x963Representation)
        keyInfo.append(serverPublicKeyBytes)
        let ikm = expand(salt: authSecret, ikm: shared, info: keyInfo, length: 32)

        let contentKey = expand(salt: salt, ikm: ikm,
                                info: Data("Content-Encoding: aes128gcm\u{00}".utf8), length: 16)
        let nonce = expand(salt: salt, ikm: ikm,
                           info: Data("Content-Encoding: nonce\u{00}".utf8), length: 12)

        let sealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: sealedBytes.dropLast(16),
            tag: sealedBytes.suffix(16))
        var plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: contentKey))

        guard plaintext.last == 0x02 else {
            return failures + ["push: record is missing the 0x02 last-record delimiter"]
        }
        plaintext = plaintext.dropLast()

        guard let decoded = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return failures + ["push: decrypted payload is not a JSON object"]
        }
        if decoded["title"] as? String != "Needs you" {
            failures.append("push: title did not survive the round trip")
        }
        if decoded["url"] as? String != "https://example.test/?id=42" {
            failures.append("push: action URL did not survive the round trip")
        }
    } catch {
        failures.append("push: the browser half could not decrypt what we send (\(error))")
    }

    return failures
}

private func testVAPIDSignature() -> [String] {
    var failures: [String] = []
    let signingKey = P256.Signing.PrivateKey()
    let vapid = VAPID(privateKey: signingKey)

    guard let advertised = base64urlDecode(vapid.publicKeyBase64URL) else {
        return ["vapid: public key is not base64url"]
    }
    if advertised.count != 65 || advertised.first != 0x04 {
        failures.append("vapid: application server key must be a 65-byte uncompressed point, got \(advertised.count)")
    }

    do {
        let jwt = try vapid.createJWT(subscriber: "mailto:jev@localhost",
                                      audience: "https://push.example.com")
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return failures + ["vapid: JWT has \(parts.count) parts"] }

        guard let signatureBytes = base64urlDecode(String(parts[2])) else {
            return failures + ["vapid: signature is not base64url"]
        }
        // ES256 wants the raw 64-byte r‖s pair, not a DER structure.
        if signatureBytes.count != 64 {
            failures.append("vapid: ES256 signature must be 64 raw bytes, got \(signatureBytes.count)")
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        if !signingKey.publicKey.isValidSignature(signature, for: signed) {
            failures.append("vapid: JWT signature does not verify")
        }

        guard let payloadData = base64urlDecode(String(parts[1])),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return failures + ["vapid: JWT payload is not JSON"]
        }
        for claim in ["aud", "exp", "sub"] where claims[claim] == nil {
            failures.append("vapid: JWT is missing the \(claim) claim")
        }
        if let exp = claims["exp"] as? Int, exp <= Int(Date().timeIntervalSince1970) {
            failures.append("vapid: JWT is already expired")
        }
    } catch {
        failures.append("vapid: \(error)")
    }
    return failures
}

private func testBase64URL() -> [String] {
    let original = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD, 0x3E, 0x3F])
    let encoded = base64url(original)
    if encoded.contains("+") || encoded.contains("/") || encoded.contains("=") {
        return ["base64url: output is not URL safe (\(encoded))"]
    }
    return base64urlDecode(encoded) == original ? [] : ["base64url: round trip lost data"]
}

/// HKDF-SHA256 for outputs of one block or less — the receiver's copy, written
/// independently of the sender's so a shared mistake cannot cancel itself out.
private func expand(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
    let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
    var block = info
    block.append(0x01)
    return Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: Data(prk)))).prefix(length)
}

/// Would a push service accept the contact jev signs with?
///
/// A shape test, run at every launch, because the value this project
/// shipped with — `mailto:jev@localhost` — was refused by Apple with
/// 403 on every single notification, and the existing assertions only
/// checked that a `sub` claim was PRESENT. "self-tests: pass" was
/// entirely compatible with push being completely dead.
public func vapidSubjectSelfTest() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ condition: Bool) {
        if !condition { failures.append("vapid: \(name)") }
    }
    check("the configured subject is one a push service will take",
          VAPIDSubject.isAcceptable(VAPIDSubject.configured))
    check("localhost is refused", !VAPIDSubject.isAcceptable("mailto:jev@localhost"))
    check("a bare hostname is refused", !VAPIDSubject.isAcceptable("mailto:jev@mac"))
    check("an address literal is refused", !VAPIDSubject.isAcceptable("mailto:jev@127.0.0.1"))
    check("http is refused", !VAPIDSubject.isAcceptable("http://example.com/jev"))
    check("nonsense is refused", !VAPIDSubject.isAcceptable("jev"))
    check("a real mailto is fine", VAPIDSubject.isAcceptable("mailto:someone@example.org"))
    check("an https page is fine", VAPIDSubject.isAcceptable("https://example.org/jev"))
    return failures
}
