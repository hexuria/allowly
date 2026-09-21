import Foundation
import Network
import JevCore

// MARK: - Public HTTP Types

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: String
    /// The body as raw bytes. Uploads are binary (audio), and round-tripping
    /// those through a String mangles or drops them entirely.
    public let bodyData: Data

    public init(method: String, path: String, headers: [String: String], body: String, bodyData: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.bodyData = bodyData
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String] = [:], body: String = "") {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public actor WebSocketSession: Sendable {
    private let nwConnection: NWConnection

    init(nwConnection: NWConnection) {
        self.nwConnection = nwConnection
    }

    /// Whether this socket is still worth sending to.
    ///
    /// The phone reconnects every two seconds while it cannot reach the Mac,
    /// and nothing was ever removing the old sessions — so a flaky connection
    /// grew the broadcast list without bound and every message was written to
    /// a pile of dead connections.
    public nonisolated var isOpen: Bool {
        switch nwConnection.state {
        case .ready, .preparing, .setup: return true
        default: return false
        }
    }

    public func send(text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        await sendFrame(opcode: 1, payload: data)
    }

    public func send(binary data: Data) async {
        await sendFrame(opcode: 2, payload: data)
    }

    fileprivate func handleFrame(_ data: Data) async {
        // WebSocket frame parsing would happen here
        // For now, this is a stub
    }

    private func sendFrame(opcode: UInt8, payload: Data) async {
        var frame = Data()

        // FIN + RSV + opcode
        frame.append(0x80 | opcode)

        // Length, with the MASK bit CLEAR. RFC 6455 §5.1: only the client masks.
        // A server frame with MASK=1 is a protocol error and the browser closes
        // the connection immediately — which is why the phone showed
        // "Disconnected" even when the handshake succeeded.
        let payloadLength = payload.count
        if payloadLength < 126 {
            frame.append(UInt8(payloadLength))
        } else if payloadLength < 65536 {
            frame.append(0x7E)
            frame.append(UInt8((payloadLength >> 8) & 0xFF))
            frame.append(UInt8(payloadLength & 0xFF))
        } else {
            frame.append(0x7F)
            frame.append(UInt8((payloadLength >> 56) & 0xFF))
            frame.append(UInt8((payloadLength >> 48) & 0xFF))
            frame.append(UInt8((payloadLength >> 40) & 0xFF))
            frame.append(UInt8((payloadLength >> 32) & 0xFF))
            frame.append(UInt8((payloadLength >> 24) & 0xFF))
            frame.append(UInt8((payloadLength >> 16) & 0xFF))
            frame.append(UInt8((payloadLength >> 8) & 0xFF))
            frame.append(UInt8(payloadLength & 0xFF))
        }

        frame.append(payload)

        nwConnection.send(content: frame, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })
    }
}

// MARK: - Bind Address Type

private enum BindAddressType {
    case loopback
    case tailnet
}

// MARK: - HTTP Server

public enum HTTPPath {
/// One spelling of a path, decided once, before anything reads it.
///
/// This is an authentication bypass if it is not done.
///
/// `requiresAuth` asked `path.hasPrefix("/api/")`; the Router split the
/// path on "/" with Swift's default `omittingEmptySubsequences: true`.
/// For `//api/pending` those disagree — the prefix test says no, the
/// split says `["api", "pending"]` and dispatches. So EVERY /api route
/// was reachable with no credential at all by typing one extra slash:
/// the pending list, `/api/decide` (the nonce is client-minted, so the
/// replay guard does not help), `/api/type` for arbitrary keystrokes,
/// `/api/screenshot` for a picture of the screen.
///
/// And it was not hypothetical. `pairingURL` ends in `/?token=…`, the
/// phone does `url.split('?')[0]`, so `baseUrl` keeps its trailing
/// slash and every single request the app has ever made went to
/// `//api/…`. The app worked because it sent the header anyway — which
/// is exactly why nobody noticed the door was open.
///
/// Two places agreeing by hand is what failed. One canonical form, at
/// the edge, is what replaces it.
    /// One named value out of the query string.
    ///
    /// Lives here rather than inside the connection actor because the
    /// router needs it too, and the alternative was a second
    /// implementation — which in this case would have been
    /// `path.contains("badges=1")`, true for `?token=abadges=1` and for
    /// `?badges=10`.
    public static func queryValue(named name: String, in path: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1)
            guard bits.count == 2, bits[0] == name else { continue }
            return String(bits[1]).removingPercentEncoding ?? String(bits[1])
        }
        return nil
    }

    public static func canonicalPath(_ raw: String) -> String {
        let route = raw.split(separator: "?", maxSplits: 1,
                              omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let query = raw.dropFirst(route.count)
        let segments = route.split(separator: "/", omittingEmptySubsequences: true)
        let collapsed = "/" + segments.joined(separator: "/")
        // A trailing slash is part of the path's identity for a directory
        // index, but jev serves "/" and named files only.
        return collapsed + query
    }
}

public actor HTTPServer {
    public struct Config: Sendable {
        public let bearerToken: String
        public let webRootPath: String?

        public init(bearerToken: String, webRootPath: String? = nil) {
            self.bearerToken = bearerToken
            self.webRootPath = webRootPath
        }
    }

    private enum BindError: Error {
        case noTailnetInterface
        case listenerCreationFailed
    }

    private let config: Config
    private var listener: NWListener?
    /// Connections arriving on any other local address are dropped at accept.
    private var allowedLocalAddress: String?
    /// Live connections. Without this the HTTPConnection created per accept is a
    /// local that deallocates as soon as start() returns — its receive handler
    /// captures self weakly, so the request is read by nobody and the client
    /// just hangs until it times out.
    private var active: [ObjectIdentifier: HTTPConnection] = [:]
    private let router: Router

    public init(config: Config) {
        self.config = config
        self.router = Router(config: config)
    }

    public func start(on port: UInt16 = 8080) async throws {
        let address = try findBindAddress()
        print("[HTTPServer] Binding to \(address.0):\(port)")

        let nwPort = NWEndpoint.Port(rawValue: port)!

        let parameters = NWParameters.tcp
        // NWListener will not accept connections when requiredLocalEndpoint is
        // set — the socket binds and then silently never completes a handshake
        // (verified: a plain BSD socket on the same address accepts instantly).
        // So the listener takes connections from any interface and every one that
        // did not arrive on the tailnet address is cancelled in acceptIsAllowed
        // below, before a single byte is read.
        //
        // This is weaker than a kernel-level bind: the port completes a TCP
        // handshake on other interfaces before being dropped. Nothing is served,
        // and a bearer token is still required, but be aware of the difference.
        parameters.allowLocalEndpointReuse = true
        // Without this NWListener binds IPv6-only (lsof shows "IPv6 TCP *:8787")
        // and every IPv4 connection to the tailnet address times out with no
        // error anywhere. Tailscale hands out IPv4, so pin the listener to v4.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        self.allowedLocalAddress = address.0
        listener = try NWListener(using: parameters, on: nwPort)

        guard let listener else {
            throw BindError.listenerCreationFailed
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[HTTPServer] Server is ready to accept connections")
            case .failed(let error):
                print("[HTTPServer] Listener failed: \(error)")
            case .cancelled:
                print("[HTTPServer] Listener cancelled")
            case .setup:
                break
            case .waiting:
                break
            @unknown default:
                break
            }
        }

        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The address the listener is pinned to, for display in the menu bar.
    ///
    /// The stored value, not a second call to `findBindAddress()`. That
    /// re-derives, and re-derivation can disagree with what was actually
    /// bound — it throws when no tailnet interface is up, and the caller's
    /// `?? "127.0.0.1"` then printed "listening on 127.0.0.1" for a server
    /// listening on the tailnet address, on the one line someone reads
    /// when pairing is broken. nil now means "not started".
    public func boundAddress() -> String? {
        allowedLocalAddress
    }

    private func handleNewConnection(_ nwConnection: NWConnection) async {
        guard acceptIsAllowed(nwConnection) else {
            nwConnection.cancel()
            return
        }
        let connection = HTTPConnection(nwConnection: nwConnection, router: router)
        let key = ObjectIdentifier(connection)
        active[key] = connection
        await connection.start { [weak self] in
            Task { await self?.release(key) }
        }
    }

    private func release(_ key: ObjectIdentifier) {
        active.removeValue(forKey: key)
    }

    /// Only serve connections that landed on the address we meant to listen on.
    /// Anything arriving over Wi-Fi or Ethernet is cut before it is read.
    private func acceptIsAllowed(_ connection: NWConnection) -> Bool {
        guard let expected = allowedLocalAddress else { return false }
        guard case let .hostPort(host, _)? = connection.currentPath?.localEndpoint else {
            // No local endpoint yet: allow, then the request still needs a token.
            return true
        }
        switch host {
        case .ipv4(let addr):
            return "\(addr)".split(separator: "%").first.map(String.init) == expected
        case .ipv6(let addr):
            return "\(addr)".contains(expected)
        case .name(let name, _):
            return name == expected
        @unknown default:
            return false
        }
    }

    private func findBindAddress() throws -> (String, BindAddressType) {
        // Default to loopback: `tailscale serve` terminates TLS on the tailnet
        // and proxies to 127.0.0.1, which is what makes the origin a secure
        // context on the phone (and therefore microphone, service worker and
        // Web Push work at all). Binding the tailnet address directly means
        // serve cannot reach us, and the phone is stuck on plain HTTP.
        // Set ALLOWLY_BIND_TAILNET=1 (or JEV_BIND_TAILNET=1) to listen on the tailnet directly.
        if Allowly.environment("ALLOWLY_BIND_TAILNET", "JEV_BIND_TAILNET") != "1" {
            return ("127.0.0.1", BindAddressType.loopback)
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            throw BindError.noTailnetInterface
        }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            defer { current = addr.pointee.ifa_next }

            guard addr.pointee.ifa_name != nil else { continue }

            let flags = Int32(addr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }

            guard let sa = addr.pointee.ifa_addr else { continue }

            if sa.pointee.sa_family == AF_INET {
                let ipv4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ip = String(cString: inet_ntoa(ipv4.sin_addr))

                if ip.hasPrefix("100.") {
                    let parts = ip.split(separator: ".").compactMap { Int($0) }
                    if parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1]) {
                        return (ip, BindAddressType.tailnet)
                    }
                }
            }
        }

        print("[HTTPServer] WARNING: No tailnet interface found (100.64.0.0/10). Phone will not be able to reach the server.")
        return ("127.0.0.1", BindAddressType.loopback)
    }

    // MARK: - Route Registration

    public nonisolated func onPendingRequests(_ handler: @escaping () async -> [ApprovalRequest]) {
        Task {
            await router.onPendingRequests(handler)
        }
    }

    public nonisolated func onJournal(_ handler: @escaping () async -> String) {
        Task { await router.onJournal(handler) }
    }

    public nonisolated func onControls(_ handler: @escaping () async -> String) {
        Task { await router.onControls(handler) }
    }

    public nonisolated func onDecide(_ handler: @escaping (String, String, Nonce) async -> ExecutionResult) {
        Task {
            await router.onDecide(handler)
        }
    }

    public nonisolated func onScreenshot(_ handler: @escaping (String?) async -> Data?) {
        Task {
            await router.onScreenshot(handler)
        }
    }

    public nonisolated func onVoiceUpload(_ handler: @escaping (Data) async -> String?) {
        Task {
            await router.onVoiceUpload(handler)
        }
    }

    public nonisolated func onCommand(
        _ handler: @escaping (String, Bool) async -> ExecutionResult) {
        Task {
            await router.onCommand(handler)
        }
    }

    public nonisolated func onSwipe(_ handler: @escaping (Double, Double, Double, Double) async -> String) {
        Task { await router.onSwipe(handler) }
    }


    public nonisolated func onTap(_ handler: @escaping (Double, Double, String) async -> String) {
        Task { await router.onTap(handler) }
    }

    public nonisolated func onType(_ handler: @escaping (String, String?, Bool) async -> String) {
        Task { await router.onType(handler) }
    }

    public nonisolated func onPolicy(_ handler: @escaping () async -> String) {
        Task { await router.onPolicy(handler) }
    }

    public nonisolated func onSetPolicy(_ handler: @escaping (String) async -> String) {
        Task { await router.onSetPolicy(handler) }
    }

    public nonisolated func onPermission(_ handler: @escaping (String) async -> String) {
        Task { await router.onPermission(handler) }
    }

    public nonisolated func onCursor(_ handler: @escaping @Sendable () async -> String) {
        Task { await router.onCursor(handler) }
    }

    public nonisolated func onVapidKey(_ handler: @escaping () async -> String) {
        Task { await router.onVapidKey(handler) }
    }

    public nonisolated func onSubscribe(_ handler: @escaping (String) async -> String) {
        Task { await router.onSubscribe(handler) }
    }

    public nonisolated func onWebSocketConnect(_ handler: @escaping (WebSocketSession) -> Void) {
        Task {
            await router.onWebSocketConnect(handler)
        }
    }
}

// MARK: - HTTP Connection Handler

private actor HTTPConnection {
    private let nwConnection: NWConnection
    private let router: Router
    private var isWebSocket = false
    private var wsSession: WebSocketSession?
    private var onClose: (@Sendable () -> Void)?
    /// Bytes seen so far for the request in flight. NWConnection hands over
    /// whatever has arrived, which is frequently just the request line — parsing
    /// that alone yields a request with no headers, and the bearer check then
    /// fails on a perfectly valid request.
    private var inbound = Data()

    init(nwConnection: NWConnection, router: Router) {
        self.nwConnection = nwConnection
        self.router = router
    }

    func start(onClose: @escaping @Sendable () -> Void) async {
        self.onClose = onClose
        nwConnection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                onClose()
            default:
                break
            }
        }

        nwConnection.start(queue: .main)
        await receiveData()
    }

    private func receiveData() async {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceivedData(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceivedData(data: Data?, isComplete: Bool, error: Error?) async {
        guard let data, !data.isEmpty else {
            if isComplete {
                nwConnection.cancel()
            } else {
                await receiveData()
            }
            return
        }

        if isWebSocket {
            if let wsSession {
                await wsSession.handleFrame(data)
            }
            if !isComplete {
                await receiveData()
            }
        } else {
            inbound.append(data)

            // Wait for the end of the header block before parsing anything.
            guard let headerEnd = Self.headerTerminator(in: inbound) else {
                // A header block has a size. Without a ceiling this loop
                // grows the buffer for as long as a client withholds the
                // blank line, and static routes need no token — so
                // anything that can reach the tailnet can do it.
                //
                // Checked ONLY while the terminator is still missing. The
                // first version tested the whole accumulated buffer on
                // every chunk, body included, so a push-to-talk longer
                // than about a minute of AAC crossed the line and came
                // back 431: "failed to process voice command", on a
                // recording that was perfectly fine.
                guard inbound.count <= Self.headerCeiling else {
                    inbound.removeAll()
                    await sendHTTPResponse(status: 431, body: "Request Header Fields Too Large")
                    nwConnection.cancel()
                    return
                }
                await receiveData()
                return
            }

            // If the request declares a body, wait for all of it too.
            if let request = parseHTTPRequest(inbound),
               let lengthText = request.headers["content-length"],
               let expected = Int(lengthText) {
                // A body has a bound too — just a much larger one, sized
                // for a long push-to-talk rather than for a header.
                guard expected <= Self.bodyCeiling, inbound.count <= Self.bodyCeiling else {
                    inbound.removeAll()
                    await sendHTTPResponse(status: 413, body: "Payload Too Large")
                    nwConnection.cancel()
                    return
                }
                if inbound.count - headerEnd < expected {
                    await receiveData()
                    return
                }
            }

            guard let request = parseHTTPRequest(inbound) else {
                await sendHTTPResponse(status: 400, body: "Bad Request")
                nwConnection.cancel()
                return
            }
            inbound.removeAll(keepingCapacity: false)

            if requiresAuth(request.path) && !isAuthorized(request) {
                await sendHTTPResponse(status: 401, body: "Unauthorized")
                nwConnection.cancel()
                return
            }

            if isWebSocketUpgrade(request) {
                await upgradeToWebSocket(request)
            } else {
                await router.handleHTTPRequest(request) { [weak self] response in
                    Task {
                        await self?.sendHTTPResponse(
                            status: response.status,
                            headers: response.headers,
                            body: response.body
                        )
                    }
                }
            }

            if !isComplete {
                await receiveData()
            }
        }
    }

    /// Index just past the blank line that ends the headers, or nil if it has
    /// not arrived yet. Tolerates bare LF as well as CRLF.
    static func headerTerminator(in data: Data) -> Int? {
        // Only ever the first `headerCeiling` bytes (plus the four the
        // terminator itself occupies). A header block longer than that
        // is refused with 431 a few lines up, so scanning past it can
        // only ever fail — and it failed expensively: this copies the
        // buffer it is handed, and it is called once per arriving chunk
        // plus twice inside `parseHTTPRequest`. On a 32 MiB upload —
        // which the body ceiling now advertises as acceptable — that is
        // four full copies of an ever-growing buffer per 64 KiB chunk,
        // tens of gigabytes of memcpy to find a marker that is in the
        // first few hundred bytes.
        let bytes = [UInt8](data.prefix(Self.headerCeiling + 4))
        // Whichever comes first, not CRLFCRLF everywhere before LFLF
        // anywhere. Scanning the entire prefix for the one and only then
        // the other meant a request with bare-LF line endings whose BODY
        // contained a CRLFCRLF — any multipart upload — took its header
        // end from inside the body. No browser writes bare-LF headers,
        // so this was unreachable in practice; "unreachable in practice"
        // is not a property a parser should depend on.
        var crlf: Int?
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4)
            where bytes[i] == 13 && bytes[i+1] == 10 && bytes[i+2] == 13 && bytes[i+3] == 10 {
                crlf = i + 4
                break
            }
        }
        var lf: Int?
        if bytes.count >= 2 {
            for i in 0...(bytes.count - 2) where bytes[i] == 10 && bytes[i+1] == 10 {
                lf = i + 2
                break
            }
        }
        switch (crlf, lf) {
        case let (c?, l?): return min(c, l)
        case let (c?, nil): return c
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        // Decode ONLY the header block as text. Decoding the whole request
        // fails outright when the body is binary (an audio upload), which made
        // every voice recording come back as 400 Bad Request.
        let headerEnd = Self.headerTerminator(in: data)
        let headerSlice = headerEnd.map { data.subdata(in: 0..<$0) } ?? data
        guard let requestString = String(data: headerSlice, encoding: .utf8)
            ?? String(data: headerSlice, encoding: .isoLatin1) else {
            return nil
        }

        // Swift treats "\r\n" as ONE grapheme cluster, so splitting on "\n" matches
        // nothing in a real CRLF request: the whole thing stays a single "line",
        // the request line still parses off the first three tokens, and every
        // header is silently dropped. Normalise the line endings first.
        let normalised = requestString.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard !lines.isEmpty else { return nil }

        let requestLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        let method = String(parts[0])
        let path = HTTPPath.canonicalPath(String(parts[1]))

        var headers: [String: String] = [:]
        var bodyStartIndex = 1

        for (index, line) in lines.enumerated() where index > 0 {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex])
                let value = String(trimmed[trimmed.index(after: colonIndex)...])
                headers[key.lowercased()] = value.trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyBytes: Data
        if let headerEnd = Self.headerTerminator(in: data), headerEnd <= data.count {
            bodyBytes = data.subdata(in: headerEnd..<data.count)
        } else {
            bodyBytes = Data()
        }
        let body = String(data: bodyBytes, encoding: .utf8) ?? ""

        return HTTPRequest(method: method, path: path, headers: headers, body: body, bodyData: bodyBytes)
    }

    /// A header block is never large. 64 KiB is generous for one.
    static let headerCeiling = 64 * 1024
    /// A body can be: `/api/voice` posts recorded audio.
    static let bodyCeiling = 32 * 1024 * 1024

    private func sendHTTPResponse(
        status: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) async {
        var allHeaders = headers
        allHeaders["content-length"] = String(body.utf8.count)
        // Every caller cancels the connection straight after responding, so
        // advertising keep-alive would be a lie.
        allHeaders["connection"] = "close"

        let statusText = HTTPStatusCode(rawValue: status)?.text ?? "Unknown"
        let headerString = allHeaders
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")

        let response = "HTTP/1.1 \(status) \(statusText)\r\n\(headerString)\r\n\r\n\(body)"

        guard let responseData = response.data(using: String.Encoding.utf8) else { return }

        // Wait for the bytes to actually be handed to the stack. Firing send with
        // a no-op completion and returning immediately means the cancel() that
        // follows tears the socket down first, and the client sees an empty reply.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nwConnection.send(
                content: responseData,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }

    /// The PWA shell itself is served without a token. A browser navigating to
    /// a page cannot send an Authorization header, so requiring one on "/" makes
    /// the app impossible to load at all: the token lives in localStorage, which
    /// needs the page first. The shell is not secret; everything that reads state
    /// or causes an action still requires the token below.
    private func requiresAuth(_ path: String) -> Bool {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        return route.hasPrefix("/api/") || route == "/ws"
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let expected = router.config.bearerToken

        if let authHeader = request.headers["authorization"],
           constantTimeCompare(authHeader, "Bearer " + expected) {
            return true
        }

        // Also accept ?token=… so the phone can bootstrap from a pairing link
        // and so the WebSocket upgrade (which cannot carry custom headers from
        // a browser) can authenticate.
        if let queryToken = HTTPPath.queryValue(named: "token", in: request.path),
           constantTimeCompare(queryToken, expected) {
            return true
        }

        return false
    }

    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        if aBytes.count != bBytes.count {
            return false
        }

        var result = 0
        for (aByte, bByte) in zip(aBytes, bBytes) {
            result |= Int(aByte ^ bByte)
        }

        return result == 0
    }

    private func isWebSocketUpgrade(_ request: HTTPRequest) -> Bool {
        guard request.method == "GET" else { return false }

        // The token arrives as a query parameter because a browser cannot set
        // an Authorization header on a WebSocket handshake, so the raw path is
        // "/ws?token=…" and comparing it to "/ws" never matched.
        let route = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard route == "/ws" else { return false }

        let upgrade = request.headers["upgrade"]?.lowercased() == "websocket"
        let connection = request.headers["connection"]?.lowercased().contains("upgrade") ?? false
        let version = request.headers["sec-websocket-version"] == "13"
        let key = request.headers["sec-websocket-key"] != nil

        return upgrade && connection && version && key
    }

    private func upgradeToWebSocket(_ request: HTTPRequest) async {
        guard let key = request.headers["sec-websocket-key"] else { return }

        let accept = generateWebSocketAccept(key)

        // Built by explicit join, not a multi-line literal: Swift drops the
        // newline before the closing delimiter, so the literal form ended with
        // "\r\n\r" and never terminated the header block. curl tolerated it;
        // Tailscale's reverse proxy waited for "\r\n\r\n" forever and the phone
        // sat on "Connecting…".
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "",
            "",
        ].joined(separator: "\r\n")

        if let responseData = response.data(using: String.Encoding.utf8) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                nwConnection.send(
                    content: responseData,
                    contentContext: .defaultMessage,
                    isComplete: false,
                    completion: .contentProcessed { _ in continuation.resume() }
                )
            }
        }

        isWebSocket = true
        let wsSession = WebSocketSession(nwConnection: nwConnection)
        self.wsSession = wsSession
        await router.handleWebSocketConnect(wsSession)
    }

    private func generateWebSocketAccept(_ key: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + guid
        let sha1 = combined.data(using: .utf8)?.sha1() ?? Data()
        return sha1.base64EncodedString()
    }
}

// MARK: - HTTP Status Code

private enum HTTPStatusCode: Int {
    case ok = 200
    case accepted = 202
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case payloadTooLarge = 413
    case headerFieldsTooLarge = 431
    case internalServerError = 500

    var text: String {
        switch self {
        case .ok: "OK"
        case .accepted: "Accepted"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .notFound: "Not Found"
        case .payloadTooLarge: "Payload Too Large"
        case .headerFieldsTooLarge: "Request Header Fields Too Large"
        case .internalServerError: "Internal Server Error"
        }
    }
}

// MARK: - SHA1 for WebSocket

private extension Data {
    func sha1() -> Data {
        var digest = [UInt8](repeating: 0, count: 20)
        withUnsafeBytes { buffer in
            var context = CC_SHA1_CTX()
            _ = CC_SHA1_Init(&context)
            _ = CC_SHA1_Update(&context, buffer.baseAddress!, CC_LONG(count))
            _ = CC_SHA1_Final(&digest, &context)
        }
        return Data(digest)
    }
}

@_silgen_name("CC_SHA1_Init")
private func CC_SHA1_Init(_ c: UnsafeMutablePointer<CC_SHA1_CTX>) -> Int32

@_silgen_name("CC_SHA1_Update")
private func CC_SHA1_Update(_ c: UnsafeMutablePointer<CC_SHA1_CTX>, _ data: UnsafeRawPointer?, _ len: CC_LONG) -> Int32

@_silgen_name("CC_SHA1_Final")
private func CC_SHA1_Final(_ md: UnsafeMutablePointer<UInt8>, _ c: UnsafeMutablePointer<CC_SHA1_CTX>) -> Int32

private struct CC_SHA1_CTX {
    var h0: UInt32 = 0
    var h1: UInt32 = 0
    var h2: UInt32 = 0
    var h3: UInt32 = 0
    var h4: UInt32 = 0
    var nl: UInt32 = 0
    var nh: UInt32 = 0
    var data = (UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(),
                UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8(), UInt8())
    var num: UInt32 = 0
}

private typealias CC_LONG = UInt32
