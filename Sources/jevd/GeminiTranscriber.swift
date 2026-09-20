import Foundation
import JevCore

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
    static let host = URL(string: "https://generativelanguage.googleapis.com")!

    /// The key, or nil when Gemini is simply not configured.
    ///
    /// Same shape as every other credential jev holds: the environment first
    /// for a terminal, then a file, because `open` inherits no shell and the
    /// file is the path that works when Jev.app is launched normally.
    static func loadAPIKey() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromEnv.isEmpty {
            return fromEnv
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev/gemini-api-key")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var model: String {
        let fromEnv = ProcessInfo.processInfo.environment["JEV_GEMINI_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fromEnv?.isEmpty == false) ? fromEnv! : defaultModel
    }

    static var isConfigured: Bool { loadAPIKey() != nil }

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
                            vocabulary: [String]) -> [String: Any] {
        var audioConfig: [String: Any] = [
            // Mandatory. Without it the call succeeds and returns nothing.
            "wordTimestamp": true,
            "diarization": false,
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
        guard let key = Self.loadAPIKey() else {
            return .failure(.recognitionFailed("No Gemini key"))
        }
        guard let audio = try? Data(contentsOf: audioURL) else {
            return .failure(.unsupportedFormat)
        }
        guard let mime = Self.mimeType(forExtension: audioURL.pathExtension) else {
            return .failure(.unsupportedFormat)
        }

        var request = URLRequest(
            url: Self.host.appendingPathComponent("v1beta/models/\(Self.model):generateContent"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Short clips. A recogniser that takes longer than this is not one
        // anybody is going to wait for mid-sentence.
        request.timeoutInterval = 20

        let body = Self.requestBody(base64Audio: audio.base64EncodedString(),
                                    mimeType: mime,
                                    vocabulary: Transcription.recognitionHints())
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

/// Use one transcriber, fall back to another.
///
/// The fallback is the point of the whole arrangement: Gemini is opt-in, and a
/// Mac with no key configured behaves exactly as it did before. It also covers
/// the cases that are not about configuration at all — a plane, a dead
/// network, an expired key — because a voice assistant that stops working
/// when the internet does is worse than one that occasionally mishears.
struct FallbackTranscriber: Transcriber {
    let preferred: Transcriber
    let fallback: Transcriber
    /// Asked each time rather than once at startup, so pasting a key in takes
    /// effect on the next thing said rather than the next launch.
    let preferredIsConfigured: @Sendable () -> Bool

    func transcribe(audioURL: URL) async -> Result<Heard, TranscriptionError> {
        guard preferredIsConfigured() else { return await fallback.transcribe(audioURL: audioURL) }

        let result = await preferred.transcribe(audioURL: audioURL)
        if case .success = result { return result }

        // Say which one spoke, once, and why the other one is being tried.
        // Without this a quietly-degrading key looks like a quietly-degrading
        // recogniser.
        if case .failure(let why) = result {
            JevLog.write("[jev] voice: Gemini did not answer (\(why)); using the built-in recogniser")
        }
        return await fallback.transcribe(audioURL: audioURL)
    }
}
