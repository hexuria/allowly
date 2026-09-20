import Foundation

/// One WebSocket to Chrome, spoken in DevTools Protocol.
///
/// Three things about this protocol make the obvious implementation wrong, and
/// all three cost a debugging session to find:
///
/// 1. **Responses and events share the socket.** Attaching to a target with
///    `flatten` — which is required, because every later call is routed by the
///    `sessionId` it returns — *guarantees* an `attachedToTarget` event. Code
///    that sends a command and then reads one frame gets the event, not its
///    answer. So there is one long-lived reader, and callers wait on an id.
/// 2. **Concurrent calls would steal each other's frames.** An actor is
///    reentrant: two calls each suspended on their own read would resume in
///    whatever order frames arrived, delivering one method's result to
///    another. The id map is what makes concurrency safe, not the actor.
/// 3. **A snapshot is far larger than the default frame limit.**
///    `URLSessionWebSocketTask.maximumMessageSize` is 1 MiB and exceeding it is
///    a receive *error* that tears the socket down. A page snapshot carries a
///    guard per node, each with up to 6000 characters of surrounding text, and
///    neither that map nor the semantic list is capped by the 250-action limit
///    — so real pages run to hundreds of kilobytes and sometimes past a
///    megabyte. The limit is raised before the socket is resumed.
///
/// Nothing here logs a URL, a page, or the endpoint's path: the path is a
/// bearer credential for a signed-in browser, and the payloads are whatever the
/// person was looking at.
public actor CDPClient {

    public enum Failure: Error, Sendable, Equatable {
        case notConnected
        case transport(String)
        /// Chrome answered with an error object.
        case protocolError(String)
        case timedOut(String)
        /// The socket closed with calls still waiting.
        case disconnected
    }

    /// Generous: a snapshot of a heavy page is the largest thing that crosses
    /// this socket, and the cost of a too-small limit is a dead connection
    /// rather than a slow one.
    static let maximumMessageSize = 64 * 1024 * 1024

    private let endpoint: ChromeDiscovery.Endpoint
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?

    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false

    public init(endpoint: ChromeDiscovery.Endpoint) {
        self.endpoint = endpoint
    }

    // MARK: - Lifecycle

    public func connect() throws {
        guard task == nil else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: endpoint.webSocketURL)
        // Before resume, or the first oversized frame kills the connection.
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()

        self.session = session
        self.task = task
        self.closed = false
        self.reader = Task { [weak self] in await self?.readLoop() }
    }

    public func close() {
        closed = true
        reader?.cancel()
        reader = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        failAllWaiting(with: .disconnected)
    }

    private func failAllWaiting(with failure: Failure) {
        let pending = waiting
        waiting.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: failure) }
    }

    // MARK: - Reading

    /// The single reader. Every frame either answers a waiting call or is an
    /// event, and an event with nobody waiting is dropped rather than queued:
    /// this backend polls the page, so a missed event costs nothing and an
    /// unbounded queue would cost memory on a busy tab.
    private func readLoop() async {
        while let task = self.task, !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let raw): data = raw
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                deliver(data)
            } catch {
                if !closed {
                    failAllWaiting(with: .transport(error.localizedDescription))
                }
                return
            }
        }
    }

    private func deliver(_ data: Data) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // No id means an event.
        guard let id = frame["id"] as? Int, let continuation = waiting.removeValue(forKey: id) else { return }

        if let error = frame["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown CDP error"
            continuation.resume(throwing: Failure.protocolError(message))
            return
        }
        continuation.resume(returning: (frame["result"] as? [String: Any]) ?? [:])
    }

    // MARK: - Calling

    /// Send one command and wait for the frame carrying its id.
    ///
    /// The timeout exists because a continuation that is never resumed leaks
    /// forever, and there are real ways for an answer never to arrive: the tab
    /// is closed, the renderer crashes, or a frame exceeds the size limit and
    /// takes the socket with it. This codebase has been bitten by exactly this
    /// before — see the note on `withCheckedContinuation` in Runtime.swift.
    @discardableResult
    public func call(_ method: String,
                     params: [String: Any] = [:],
                     sessionID: String? = nil,
                     timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let task, !closed else { throw Failure.notConnected }

        let id = nextID
        nextID += 1

        var frame: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { frame["params"] = params }
        if let sessionID { frame["sessionId"] = sessionID }

        guard let encoded = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: encoded, encoding: .utf8) else {
            throw Failure.transport("could not encode \(method)")
        }

        // Armed before the send, so an answer that arrives immediately still
        // finds someone waiting.
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(id, method: method)
        }
        defer { timer.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { await self?.sendFailed(id, error.localizedDescription) }
            }
        }
    }

    private func expire(_ id: Int, method: String) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(throwing: Failure.timedOut(method))
    }

    private func sendFailed(_ id: Int, _ message: String) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(throwing: Failure.transport(message))
    }

    /// How many calls are still waiting. For assertions and for noticing a leak.
    public var outstanding: Int { waiting.count }
}
