import Foundation
import JevCore
import JevWeb

/// Transcription by Gemini, when there is a key for it.
///
/// Apple's recogniser is what jev shipped with and it is not good enough for
/// everyone. Measured on a Mac already set to `en-PH`, with the right words in
/// its hint list: "press cmd 1" came back as "prayers for man one", and
/// "create new tab" as "create new dog". Locale and biasing both helped and
/// neither fixed it.
///
/// So this exists as an alternative, and the choice is the person's: with no
/// key configured, nothing changes and Apple's recogniser handles everything
/// exactly as before. See `FallbackTranscriber`.
///
/// Two things learned from Google's own demo client rather than from the docs,
/// both of which fail quietly rather than loudly:
///
/// - `wordTimestamp` **must** be true. Without it the request succeeds and the
///   transcript comes back empty.
/// - `mode` parses on this endpoint and then returns an empty text part. It
///   only works on the newer `v1beta/interactions` surface, which is not used
///   here.
struct GeminiTranscriber: Transcriber {

    static let defaultModel = "gemini-3.5-transcribe"
    static let google = URL(string: "https://generativelanguage.googleapis.com")!

    /// Where transcription is sent.
    ///
    /// Google unless something local says otherwise. The override exists so
    /// the recording can go through a gateway on this machine that holds the
    /// credential and counts what it costs, rather than every client keeping
    /// its own Google key.
    ///
    /// **Loopback only**, exactly as `JevAPI.endpoint` is, and for a stronger
    /// reason: this carries a recording of somebody's voice. A mistyped
    /// variable must not be able to send that somewhere new, so anything that
    /// is not a local address is ignored and Google is used.
    static var host: URL {
        resolvedHost(raw: Allowly.environment("ALLOWLY_GEMINI_BASE_URL", "JEV_GEMINI_BASE_URL"))
    }

    /// Pure, so "a non-local address is ignored" is a launch assertion rather
    /// than a sentence in a comment.
    static func resolvedHost(raw: String?) -> URL {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), Allowly.isLoopback(url)
        else { return google }
        return url
    }

    /// Whose credential a given host is owed.
    ///
    /// Pure, and the reason it exists is that getting it wrong is the worst
    /// thing in this file: sending the Google key to a local gateway, or the
    /// gateway key to Google, hands a working credential to somebody who
    /// should never have seen it. So it is one function, decided by the host
    /// alone, and asserted at launch.
    enum KeyHolder: Equatable {
        case google
        case localGateway
    }

    static func keyHolder(for host: URL) -> KeyHolder {
        Allowly.isLoopback(host) ? .localGateway : .google
    }

    /// The key for wherever this is pointed.
    ///
    /// Through the gateway it is the gateway's key — the same one the web
    /// text model already uses — because that is who is being asked. Google's
    /// key stays where it is and is not sent.
    static func key(for host: URL) -> String? {
        switch keyHolder(for: host) {
        case .google: return loadAPIKey()
        case .localGateway: return WebTextModel.loadAPIKey()
        }
    }

    /// Where a key set from the menu bar lives.
    static let keychainKey = "gemini-api-key"

    /// The key, or nil when Gemini is simply not configured.
    ///
    /// Three sources, in the order that lets each one win where it should:
    /// the environment for a terminal launch, then the Keychain, which is
    /// where the menu bar puts it and the right place for a credential, then
    /// a file for anyone who would rather manage it that way. `open` inherits
    /// no shell, so the environment alone would never work for Jev.app.
    ///
    /// The Keychain read is timed out. A Keychain read can raise a prompt,
    /// and a prompt nobody is there to answer blocks forever — that hung the
    /// daemon once already tonight, on this same pattern.
    static func loadAPIKey() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromEnv.isEmpty {
            return fromEnv
        }
        if let stored = KeychainManager.shared.retrieveWithTimeout(key: keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        let url = Allowly.supportDirectory.appendingPathComponent("gemini-api-key")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Keep a key typed into the menu bar.
    static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.recognitionFailed("Empty key") }
        try KeychainManager.shared.store(key: keychainKey, value: trimmed)
        // That one was set, never what it is.
        JevLog.write("[allowly] Gemini key saved; transcription will use \(model)")
    }

    static func clearAPIKey() {
        try? KeychainManager.shared.store(key: keychainKey, value: "")
        JevLog.write("[allowly] Gemini key removed; using the built-in recogniser")
    }

    /// Where the key in use came from, for the menu. Never the key.
    static func sourceDescription() -> String {
        if keyHolder(for: host) == .localGateway {
            return "from the local gateway"
        }
        if ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty == false {
            return "from the environment"
        }
        if KeychainManager.shared.retrieveWithTimeout(key: keychainKey)?.isEmpty == false {
            return "in your Keychain"
        }
        return "from a file"
    }

    static var model: String {
        let fromEnv = Allowly.environment("ALLOWLY_GEMINI_MODEL", "JEV_GEMINI_MODEL")
        return fromEnv ?? defaultModel
    }

    /// Configured means "there is a key for wherever this is pointed" — which
    /// through a gateway is the gateway's key, not Google's. Checking only for
    /// a Google key would hide the feature from somebody who set this up the
    /// new way.
    static var isConfigured: Bool { key(for: host) != nil }

    /// What Gemini is told the audio is.
    ///
    /// jev sniffs the container from its magic bytes rather than trusting the
    /// phone, which calls everything ".webm" and sends MP4. Mapped rather than
    /// passed through: an unrecognised media type is rejected outright, and
    /// guessing wrong is a failed request rather than a worse transcript.
    static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "m4a", "mp4", "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mp3"
        case "ogg": return "audio/ogg"
        case "aiff", "aif": return "audio/aiff"
        // WebM/Opus is not in Gemini's list, and jev already transcodes it for
        // Apple's recogniser for the same reason.
        default: return nil
        }
    }

    /// The request body.
    ///
    /// Pure, so the two quiet failure modes above are launch assertions rather
    /// than something to rediscover.
    static func requestBody(base64Audio: String, mimeType: String,
                            vocabulary: [String],
                            languageCodes: [String]) -> [String: Any] {
        var audioConfig: [String: Any] = [
            // Mandatory. Without it the call succeeds and returns nothing.
            "wordTimestamp": true,
            "diarization": false,
            // The same language the menu bar already picks, so one setting
            // governs both recognisers. Empty is not a missing value: it is
            // how this API is told to detect across eighty-five languages,
            // which is what someone switching between English and Tagalog
            // mid-sentence actually wants.
            //
            // Safe here, and not everywhere. On the newer interactions
            // surface, pairing a language code with `mode: "smart"` silently
            // reverts to verbatim — HTTP 200, no error, no signal — which
            // Google's own client documents and pins with a test. jev uses
            // neither that surface nor that mode.
            "languageCodes": languageCodes,
        ]
        // The same phrases Apple's recogniser is biased with. A vocabulary is
        // the one thing that reliably rescues a short unusual word — "Ghostty"
        // is heard as "ghost tea" by anything not told otherwise.
        if !vocabulary.isEmpty { audioConfig["customVocabulary"] = vocabulary }

        return [
            "contents": [["role": "user",
                          "parts": [["inline_data": ["mime_type": mimeType, "data": base64Audio]]]]],
            "generationConfig": [
                "temperature": 0,
                "audioTranscriptionConfig": audioConfig,
            ],
        ]
    }

    /// Pull the transcript out of a `:generateContent` reply.
    static func transcript(fromBody data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Transcriber

    func transcribe(audioURL: URL) async -> Result<Heard, TranscriptionError> {
        let host = Self.host
        guard let key = Self.key(for: host) else {
            return .failure(.recognitionFailed(
                Self.keyHolder(for: host) == .localGateway
                    ? "No gateway key" : "No Gemini key"))
        }
        guard let audio = try? Data(contentsOf: audioURL) else {
            return .failure(.unsupportedFormat)
        }
        guard let mime = Self.mimeType(forExtension: audioURL.pathExtension) else {
            return .failure(.unsupportedFormat)
        }

        // Resolved once above, so the key and the destination cannot come
        // from two different readings of the variable.
        var request = URLRequest(
            url: host.appendingPathComponent("v1beta/models/\(Self.model):generateContent"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Short clips. A recogniser that takes longer than this is not one
        // anybody is going to wait for mid-sentence.
        request.timeoutInterval = 20

        let body = Self.requestBody(base64Audio: audio.base64EncodedString(),
                                    mimeType: mime,
                                    vocabulary: Transcription.recognitionHints(),
                                    languageCodes: VoiceLocale.languageCodes)
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.recognitionFailed("Could not encode the request"))
        }
        request.httpBody = encoded

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // The transport's message, never the request: the body is the
            // recording.
            return .failure(.recognitionFailed(error.localizedDescription))
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failure(.recognitionFailed("Gemini returned HTTP \(http.statusCode)"))
        }
        guard let text = Self.transcript(fromBody: data) else {
            return .failure(.noSpeechDetected)
        }

        // One reading, and no per-word score to average. Reported honestly
        // rather than dressed up: `SpeechRepair` picks between competing
        // readings and there are none to pick between, so it will pass this
        // straight through — which is the right behaviour, not a degradation
        // to paper over.
        return .success(Heard(best: text, alternatives: [], confidence: 1.0))
    }
}

/// Use one transcriber, fall back to another — and keep the other's ear.
///
/// The fallback is the point of the whole arrangement: Gemini is opt-in, and
/// a Mac with no key configured behaves exactly as it did before. It also
/// covers the cases that are not about configuration at all — a plane, a
/// dead network, an expired key — because a voice assistant that stops
/// working when the internet does is worse than one that occasionally
/// mishears.
///
/// The two run TOGETHER when both are available, not one after the other.
/// Gemini returns one reading; Apple returns several. Three of jev's cheapest
/// rescues live in `SpeechRepair` and only work with more than one reading —
/// a reading that names a control on screen, a lower-ranked reading that
/// parses when the top one does not, and the no-op when all readings mean
/// the same thing. Switching to Gemini alone silently turned all three off.
/// So Gemini's reading is the answer, and Apple's readings ride along as the
/// alternatives. Apple is local and free; running it in parallel costs the
/// slower of the two, not the sum.
struct FallbackTranscriber: Transcriber {
    let preferred: Transcriber
    let fallback: Transcriber
    /// Asked each time rather than once at startup, so pasting a key in takes
    /// effect on the next thing said rather than the next launch.
    let preferredIsConfigured: @Sendable () -> Bool

    func transcribe(audioURL: URL) async -> Result<Heard, TranscriptionError> {
        guard preferredIsConfigured() else { return await fallback.transcribe(audioURL: audioURL) }

        async let first = preferred.transcribe(audioURL: audioURL)
        async let second = fallback.transcribe(audioURL: audioURL)
        let (fromPreferred, fromFallback) = await (first, second)

        switch (fromPreferred, fromFallback) {
        case (.success(let main), .success(let ear)):
            return .success(Self.merged(preferred: main, secondary: ear))
        case (.success(let main), .failure):
            return .success(main)
        case (.failure(let why), .success(let ear)):
            // Say which one spoke, once, and why. Without this a quietly
            // degrading key looks like a quietly degrading recogniser.
            JevLog.write("[allowly] voice: Gemini did not answer (\(why)); using the built-in recogniser")
            return .success(ear)
        case (.failure, .failure(let why)):
            return .failure(why)
        }
    }

    /// Pure: the preferred reading, with the other recogniser's readings as
    /// alternatives. The preferred best is never repeated among them, and
    /// nothing is dropped from what the second ear heard.
    static func merged(preferred: Heard, secondary: Heard) -> Heard {
        var seen: Set<String> = [preferred.best]
        let extra = ([secondary.best] + secondary.alternatives)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Heard(best: preferred.best,
                     alternatives: preferred.alternatives + extra,
                     confidence: preferred.confidence)
    }
}
