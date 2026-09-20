import Foundation
import JevCore

actor Router {
    // MARK: - Handler Types

    typealias PendingRequestsHandler = () async -> [ApprovalRequest]
    typealias ControlsHandler = () async -> String
    typealias JournalHandler = () async -> String
    typealias DecideHandler = (String, String, Nonce) async -> ExecutionResult
    typealias ScreenshotHandler = (String?) async -> Data?
    typealias VoiceUploadHandler = (Data) async -> String?
    typealias CommandHandler = (String) async -> ExecutionResult
    typealias VapidKeyHandler = () async -> String
    typealias SubscribeHandler = (String) async -> String
    typealias PolicyHandler = () async -> String
    typealias TypeHandler = (String, String?, Bool) async -> String
    typealias TapHandler = (Double, Double, String) async -> String
    typealias SwipeHandler = (Double, Double, Double, Double) async -> String
    typealias SetPolicyHandler = (String) async -> String
    /// Claude Code's PermissionRequest hook. Body in, decision JSON out.
    typealias PermissionHandler = (String) async -> String
    typealias WebSocketConnectHandler = (WebSocketSession) -> Void

    // MARK: - State

    let config: HTTPServer.Config

    private var pendingRequestsHandler: PendingRequestsHandler?
    private var controlsHandler: ControlsHandler?
    private var journalHandler: JournalHandler?
    private var decideHandler: DecideHandler?
    private var screenshotHandler: ScreenshotHandler?
    private var voiceUploadHandler: VoiceUploadHandler?
    private var commandHandler: CommandHandler?
    private var vapidKeyHandler: VapidKeyHandler?
    private var subscribeHandler: SubscribeHandler?
    private var policyHandler: PolicyHandler?
    private var typeHandler: TypeHandler?
    /// Returns the pointer position as a JSON object, normalised 0..1.
    private var cursorHandler: (@Sendable () async -> String)?
    private var tapHandler: TapHandler?
    private var swipeHandler: SwipeHandler?
    private var setPolicyHandler: SetPolicyHandler?
    private var permissionHandler: PermissionHandler?
    private var webSocketConnectHandler: WebSocketConnectHandler?
    private let staticFiles: StaticFiles

    init(config: HTTPServer.Config) {
        self.config = config
        self.staticFiles = StaticFiles(webRootPath: config.webRootPath)
    }

    // MARK: - Handler Registration

    func onPendingRequests(_ handler: @escaping PendingRequestsHandler) {
        self.pendingRequestsHandler = handler
    }

    func onControls(_ handler: @escaping ControlsHandler) { self.controlsHandler = handler }
    func onJournal(_ handler: @escaping JournalHandler) { self.journalHandler = handler }

    func onDecide(_ handler: @escaping DecideHandler) {
        self.decideHandler = handler
    }

    func onScreenshot(_ handler: @escaping ScreenshotHandler) {
        self.screenshotHandler = handler
    }

    func onVoiceUpload(_ handler: @escaping VoiceUploadHandler) {
        self.voiceUploadHandler = handler
    }

    func onCommand(_ handler: @escaping CommandHandler) {
        self.commandHandler = handler
    }

    func onVapidKey(_ handler: @escaping VapidKeyHandler) { self.vapidKeyHandler = handler }
    func onSubscribe(_ handler: @escaping SubscribeHandler) { self.subscribeHandler = handler }
    func onType(_ handler: @escaping TypeHandler) { self.typeHandler = handler }
    func onCursor(_ handler: @escaping @Sendable () async -> String) { self.cursorHandler = handler }
    func onTap(_ handler: @escaping TapHandler) { self.tapHandler = handler }
    func onSwipe(_ handler: @escaping SwipeHandler) { self.swipeHandler = handler }
    func onPolicy(_ handler: @escaping PolicyHandler) { self.policyHandler = handler }
    func onSetPolicy(_ handler: @escaping SetPolicyHandler) { self.setPolicyHandler = handler }
    func onPermission(_ handler: @escaping PermissionHandler) { self.permissionHandler = handler }

    func onWebSocketConnect(_ handler: @escaping WebSocketConnectHandler) {
        self.webSocketConnectHandler = handler
    }

    /// Accept every timestamp shape the client might send.
    ///
    /// The browser uses Date.now() — epoch milliseconds as a NUMBER — while
    /// this decoder expected an ISO-8601 string, so every decision POST failed
    /// to decode and came back 400 "Invalid request". JavaScript's
    /// toISOString() also emits fractional seconds, which the strict .iso8601
    /// strategy rejects. Accept all of them rather than depend on one client
    /// getting it exactly right.
    static let lenientDates = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()

        if let number = try? container.decode(Double.self) {
            // Heuristic: anything past ~1973 in seconds is milliseconds.
            let seconds = number > 100_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        let text = try container.decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognised date: \(text)"
        )
    }

    // MARK: - Request Handling

    func handleHTTPRequest(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) async {
        // Match on the path alone. Query strings are real here — the phone
        // authenticates with ?token=… — and matching the raw path would 404
        // every request that carries one.
        let route = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let components = route.split(separator: "/").map(String.init)

        // Route dispatch
        if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "pending" {
            await handleGetPending(completion)
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "decide" {
            await handlePostDecide(request, completion)
        } else if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "journal" {
            let json = await (journalHandler?() ?? "[]")
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "controls" {
            let json = await (controlsHandler?() ?? "[]")
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "screenshot" {
            await handleGetScreenshot(request, completion)
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "voice" {
            await handlePostVoice(request, completion)
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "command" {
            await handlePostCommand(request, completion)
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "tap" {
            guard let data = request.body.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let x = payload["x"] as? Double, let y = payload["y"] as? Double else {
                completion(HTTPResponse(status: 400, headers: [:], body: "Invalid request"))
                return
            }
            let kind = payload["kind"] as? String
                ?? ((payload["secondary"] as? Bool ?? false) ? "right" : "click")
            let json = await (tapHandler?(x, y, kind) ?? #"{"ok":false}"#)
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "swipe" {
            guard let data = request.body.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                  let dx = payload["dx"] as? Double, let dy = payload["dy"] as? Double else {
                completion(HTTPResponse(status: 400, headers: [:], body: "Invalid request"))
                return
            }
            let json = await (swipeHandler?(x, y, dx, dy) ?? #"{"ok":false}"#)
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "type" {
            guard let data = request.body.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = payload["text"] as? String else {
                completion(HTTPResponse(status: 400, headers: [:], body: "Invalid request"))
                return
            }
            let field = payload["field"] as? String
            let secret = payload["secret"] as? Bool ?? false
            let result = await (typeHandler?(text, field, secret) ?? #"{"ok":false}"#)
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json",
                                              "cache-control": "no-store"],
                                    body: result))
        } else if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "policy" {
            let json = await (policyHandler?() ?? "{}")
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json",
                                              "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "policy" {
            let json = await (setPolicyHandler?(request.body) ?? "{}")
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json",
                                              "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "permission" {
            // The Claude Code hook. It gives up after 6 seconds, so whatever
            // happens here must answer well inside that.
            let json = await (permissionHandler?(request.body)
                ?? #"{"allow":false,"reason":"jev has no permission handler"}"#)
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json",
                                              "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "GET" && components.count == 2 && components[0] == "api" && components[1] == "vapid-key" {
            let json = await (vapidKeyHandler?() ?? "{}")
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else if request.method == "POST" && components.count == 2 && components[0] == "api" && components[1] == "subscribe" {
            let json = await (subscribeHandler?(request.body) ?? #"{"ok":false}"#)
            completion(HTTPResponse(status: 200,
                                    headers: ["content-type": "application/json", "cache-control": "no-store"],
                                    body: json))
        } else {
            // Try to serve static file from web root
            await staticFiles.serve(path: route) { data, mimeType in
                if let data {
                    // No cache headers at all means Safari caches heuristically,
                    // so a fixed app.js can keep serving the old one and you end
                    // up debugging code that is no longer on disk.
                    completion(HTTPResponse(
                        status: 200,
                        headers: [
                            "content-type": mimeType,
                            "cache-control": "no-cache, must-revalidate",
                        ],
                        body: String(data: data, encoding: .utf8) ?? ""
                    ))
                } else {
                    completion(HTTPResponse(status: 404, headers: [:], body: "Not Found"))
                }
            }
        }
    }

    func handleWebSocketConnect(_ session: WebSocketSession) async {
        webSocketConnectHandler?(session)
    }

    // MARK: - Route Handlers

    private func handleGetPending(_ completion: @escaping (HTTPResponse) -> Void) async {
        guard let handler = pendingRequestsHandler else {
            completion(HTTPResponse(status: 500, headers: [:], body: "Handler not configured"))
            return
        }

        let requests = await handler()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(requests)
            let body = String(data: data, encoding: .utf8) ?? "[]"
            completion(HTTPResponse(
                status: 200,
                headers: [
                    "content-type": "application/json",
                    "cache-control": "no-store, no-cache, must-revalidate",
                ],
                body: body
            ))
        } catch {
            completion(HTTPResponse(status: 500, headers: [:], body: "JSON encoding failed"))
        }
    }

    private func handlePostDecide(_ request: HTTPRequest, _ completion: @escaping (HTTPResponse) -> Void) async {
        guard let handler = decideHandler else {
            completion(HTTPResponse(status: 500, headers: [:], body: "Handler not configured"))
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Self.lenientDates

        guard let body = request.body.data(using: .utf8),
              let payload = try? decoder.decode(DecidePayload.self, from: body) else {
            completion(HTTPResponse(status: 400, headers: [:], body: "Invalid request"))
            return
        }

        let result = await handler(payload.requestId, payload.optionId, payload.nonce)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            let body = String(data: data, encoding: .utf8) ?? ""
            completion(HTTPResponse(
                status: 202,
                headers: ["content-type": "application/json"],
                body: body
            ))
        } catch {
            completion(HTTPResponse(status: 500, headers: [:], body: "JSON encoding failed"))
        }
    }

    private func handleGetScreenshot(_ request: HTTPRequest, _ completion: @escaping (HTTPResponse) -> Void) async {
        guard let handler = screenshotHandler else {
            completion(HTTPResponse(status: 500, headers: [:], body: "Handler not configured"))
            return
        }

        let windowId = parseQueryParameter(request.path, "window")

        if let imageData = await handler(windowId) {
            let base64 = imageData.base64EncodedString()
            // Every poll requests the same URL, so without this the browser
            // happily serves a cached frame and the screen appears frozen on
            // whatever it showed first.
            completion(HTTPResponse(
                status: 200,
                headers: [
                    "content-type": "application/json",
                    "cache-control": "no-store, no-cache, must-revalidate",
                    "pragma": "no-cache",
                ],
                // The pointer rides along with the frame it belongs to. A
                // separate poll would race the image and put the marker where
                // the cursor used to be.
                body: "{\"data\":\"\(base64)\",\"cursor\":\(await cursorHandler?() ?? "null")}"
            ))
        } else {
            completion(HTTPResponse(status: 404, headers: [:], body: "Screenshot not available"))
        }
    }

    private func handlePostVoice(_ request: HTTPRequest, _ completion: @escaping (HTTPResponse) -> Void) async {
        guard let handler = voiceUploadHandler else {
            completion(HTTPResponse(status: 500, headers: [:], body: "Handler not configured"))
            return
        }

        // The browser sends multipart/form-data. Pull the file part out of the
        // raw bytes; fall back to treating the whole body as the audio.
        let contentType = request.headers["content-type"] ?? ""
        let audioData: Data
        if contentType.contains("multipart/form-data"),
           let boundary = contentType.split(separator: "=").last.map(String.init),
           let part = Self.multipartFilePart(in: request.bodyData, boundary: boundary) {
            audioData = part
        } else {
            audioData = request.bodyData
        }

        guard !audioData.isEmpty else {
            completion(HTTPResponse(status: 400, headers: [:], body: "Empty audio upload"))
            return
        }

        guard let transcript = await handler(audioData) else {
            completion(HTTPResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Could not transcribe that audio"}"#
            ))
            return
        }

        // Act on what was said. Returning only the text made the button a
        // dictaphone: you spoke, it echoed, and nothing happened on the Mac.
        var payload: [String: Any] = ["transcript": transcript]
        if let runCommand = commandHandler {
            let result = await runCommand(transcript)
            payload["decision"] = result.status == .ok ? "Done — \(result.reason)" : "Not run — \(result.reason)"
            payload["executed"] = result.status == .ok
        } else {
            payload["decision"] = "Heard, but no command handler is configured"
            payload["executed"] = false
        }

        // Build with JSONSerialization: string interpolation broke the response
        // as soon as a transcript contained a quote.
        let body = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"error":"encoding failed"}"#

        completion(HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: body
        ))
    }

    /// Extract the first file payload from a multipart/form-data body.
    static func multipartFilePart(in data: Data, boundary: String) -> Data? {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)

        guard let first = data.range(of: delimiter) else { return nil }
        guard let bodyStart = data.range(of: headerEnd, in: first.upperBound..<data.endIndex) else { return nil }
        let next = data.range(of: delimiter, in: bodyStart.upperBound..<data.endIndex)
        var end = next?.lowerBound ?? data.endIndex
        // Trim the CRLF that precedes the closing boundary.
        if end > bodyStart.upperBound + 1 { end -= 2 }
        guard end > bodyStart.upperBound else { return nil }
        return data.subdata(in: bodyStart.upperBound..<end)
    }

    private func handlePostCommand(_ request: HTTPRequest, _ completion: @escaping (HTTPResponse) -> Void) async {
        guard let handler = commandHandler else {
            completion(HTTPResponse(status: 500, headers: [:], body: "Handler not configured"))
            return
        }

        let decoder = JSONDecoder()
        guard let body = request.body.data(using: .utf8),
              let payload = try? decoder.decode(CommandPayload.self, from: body) else {
            completion(HTTPResponse(status: 400, headers: [:], body: "Invalid request"))
            return
        }

        let result = await handler(payload.command)

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(result)
            let body = String(data: data, encoding: .utf8) ?? ""
            completion(HTTPResponse(
                status: 202,
                headers: ["content-type": "application/json"],
                body: body
            ))
        } catch {
            completion(HTTPResponse(status: 500, headers: [:], body: "JSON encoding failed"))
        }
    }

    // MARK: - Utilities

    private func parseQueryParameter(_ path: String, _ name: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let queryString = String(path[path.index(after: queryStart)...])

        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == name {
                return String(parts[1]).removingPercentEncoding
            }
        }

        return nil
    }
}

// MARK: - Request/Response Payloads

private struct DecidePayload: Codable {
    let requestId: String
    let optionId: String
    let nonce: Nonce
}

private struct CommandPayload: Codable {
    let command: String
}
