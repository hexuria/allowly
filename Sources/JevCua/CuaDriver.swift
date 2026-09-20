import Foundation
import JevCore

/// A thin client for Cua Driver, the thing that now does jev's looking and
/// pointing on the Mac.
///
/// Why a separate process at all: the driver holds its own TCC grants under
/// `com.trycua.driver`, so Accessibility and Screen Recording are approved for
/// *it* rather than for us. That is the whole point — the grants survive our
/// rebuilds, and the driver's refusals are honest in a way our own tree walk
/// never was. It says "this window is on another Space and I will not guess"
/// instead of clicking the wrong thing.
///
/// We talk to it over its unix socket, one line of JSON each way:
///
///     {"method":"call","name":"<tool>","arguments":{…}}
///     {"ok":true,"result":{"content":[…],"structuredContent":{…}}}
///
/// It began on the CLI, which was a mistake worth writing down. Every
/// `cua-driver call` is a process launch, and each one measured **3.3
/// seconds** on this Mac — almost entirely spawn overhead, since a trivial
/// `get_screen_size` cost the same as reading a whole window tree. A single
/// spoken command touches the screen several times, so that alone put thirty
/// seconds between saying a thing and it happening. The same call over the
/// socket takes **0.007s**. The CLI is still here to start the daemon.
public actor CuaDriver {

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ text: String) { self.description = text }
    }

    /// Where the driver lives. The bundle path first, then anything on PATH,
    /// so a Homebrew or cargo install still works.
    private static let candidates = [
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
        "/usr/local/bin/cua-driver",
        "/opt/homebrew/bin/cua-driver",
    ]

    public static let shared = CuaDriver()

    /// Where to send a line about what the backend decided. jevd points this
    /// at its own log. Without it, "it said Clicked and nothing happened" is
    /// unfalsifiable — which route it took is the whole answer.
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?

    public static func note(_ message: String) { log?("[cua] " + message) }

    private var resolvedBinary: String?
    private var daemonConfirmed = false

    public init() {}

    // MARK: - Availability

    /// The driver binary, if it is installed at all.
    public func binary() -> String? {
        if let resolvedBinary { return resolvedBinary }
        let fm = FileManager.default
        for path in Self.candidates where fm.isExecutableFile(atPath: path) {
            resolvedBinary = path
            return path
        }
        if let onPath = Self.which("cua-driver") {
            resolvedBinary = onPath
            return onPath
        }
        return nil
    }

    /// True once the daemon has answered at least one call.
    ///
    /// Deliberately not a live probe on every command: `status` is another
    /// process spawn, and the calls themselves already fail loudly.
    public func isReady() -> Bool { daemonConfirmed }

    /// Make sure the daemon is up, starting it if it is not.
    ///
    /// Starting it ourselves is safe: it binds a user-owned unix socket, holds
    /// no port, and `cua-driver stop` ends it. It is *not* the same as granting
    /// it anything — TCC consent is a separate, human-only step.
    @discardableResult
    public func ensureRunning() async -> Bool {
        if daemonConfirmed { return true }
        // One starter at a time.
        //
        // `daemonConfirmed` is checked, then this actor SUSPENDS on the
        // status call — and a second caller entering during that
        // suspension saw the same `false` and also reached `task.run()`.
        // Two `cua-driver serve` processes then raced for the same unix
        // socket. The loser fails to bind, so it heals itself, but it
        // leaves a stray process and makes "the driver will not start"
        // mean two different things.
        if let inFlight = starting {
            return await inFlight.value
        }
        let attempt = Task { await startDriver() }
        starting = attempt
        let started = await attempt.value
        starting = nil
        return started
    }

    private var starting: Task<Bool, Never>?

    private func startDriver() async -> Bool {
        guard let bin = binary() else { return false }

        if (try? await run(bin, ["status"], timeout: 5)).map({ $0.contains("is running") }) == true {
            daemonConfirmed = true
            return true
        }

        let socket = Self.socketPath()
        try? FileManager.default.createDirectory(
            atPath: (socket as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["serve", "--socket", socket]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }

        // It binds the socket in well under a second; give it a few tries
        // rather than one arbitrary sleep.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(250))
            if let out = try? await run(bin, ["status"], timeout: 5), out.contains("is running") {
                daemonConfirmed = true
                return true
            }
        }
        return false
    }

    private static func socketPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Caches/cua-driver/cua-driver.sock"
    }

    // MARK: - Calling tools

    /// Invoke one driver tool and hand back its decoded JSON object.
    ///
    /// Every failure is an error rather than an empty result, because a tool
    /// that did not run and a tool that found nothing mean opposite things to
    /// the caller — and conflating them is how you end up clicking blind.
    public func call(_ tool: String,
                     _ arguments: [String: Any] = [:],
                     timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let bin = binary() else {
            throw Failure("Cua Driver is not installed — jev needs it to see the screen. "
                + "Install it from trycua.com, then run `cua-driver permissions grant`.")
        }
        guard await ensureRunning() else {
            throw Failure("Cua Driver is installed but its daemon will not start")
        }

        _ = bin
        do {
            return try await invoke(tool, arguments, timeout: timeout)
        } catch let failure as Failure where Self.isSessionEnded(failure.description) {
            // The driver's session can lapse — idle, or revoked out from
            // under us — and every call after that is refused. It came back
            // as an empty control list and a dead pointer with no clue why.
            // Start a new one and try again, once.
            JevLog("[cua] session had ended; starting a new one")
            _ = try? await invoke("start_session", [:], timeout: 20)
            return try await invoke(tool, arguments, timeout: timeout)
        }
    }

    private func JevLog(_ message: String) { Self.log?(message) }

    /// Has the driver's session lapsed?
    ///
    /// Matched on the prose as well as the code, because the same refusal
    /// arrives by two routes: as a structured `refusal` carrying
    /// `code: session_ended`, and — first, as it turns out — as a tool error
    /// whose only text is the sentence. Matching the code alone meant the
    /// retry never ran and every call stayed dead until a restart.
    static func isSessionEnded(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("session_ended") || lower.contains("session has ended")
    }

    private func invoke(_ tool: String,
                        _ arguments: [String: Any],
                        timeout: TimeInterval) async throws -> [String: Any] {
        let request = Self.requestBody(tool: tool, arguments: arguments)
        let line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let reply = try await send(line, timeout: timeout)

        guard let object = try? JSONSerialization.jsonObject(with: reply),
              let envelope = object as? [String: Any] else {
            throw Failure(Self.firstLine(of: String(decoding: reply, as: UTF8.self)))
        }
        if envelope["ok"] as? Bool == false {
            throw Failure((envelope["error"] as? String) ?? "Cua Driver refused \(tool)")
        }
        let result = (envelope["result"] as? [String: Any]) ?? envelope

        // A tool can fail inside a successful envelope. `ok` only says the
        // socket carried the request; `isError` says whether the tool did
        // anything. Not reading it meant a refusal — a missing field, a
        // window that moved, a control that is not there — came back as
        // success, and the phone said "Type “hello”" while nothing was typed.
        if Self.isToolError(result) {
            throw Failure(Self.toolMessage(result) ?? "Cua Driver refused \(tool)")
        }

        // The useful half is structuredContent; `content` is the same thing
        // spelled out for a human to read.
        if let structured = result["structuredContent"] as? [String: Any] {
            if let error = structured["error"] as? String { throw Failure(error) }
            // A refusal rides inside a successful envelope too. Handing it
            // back as data meant the caller looked for "apps" or "elements",
            // found neither, and reported an empty screen — which is how a
            // lapsed session became "nothing pressable on screen".
            if let refusal = structured["refusal"] as? [String: Any] {
                let code = (refusal["code"] as? String) ?? ""
                let text = (refusal["message"] as? String) ?? "Cua Driver refused \(tool)"
                throw Failure(code.isEmpty ? text : "\(code): \(text)")
            }
            if structured["status"] as? String == "refused" {
                throw Failure("Cua Driver refused \(tool)")
            }
            return structured
        }
        if let error = result["error"] as? String { throw Failure(error) }
        return result
    }

    /// The wire format, built in one place so it can be asserted offline.
    ///
    /// The key is `args`. Not `arguments` — that spelling is accepted by the
    /// socket, reaches the tool with nothing in it, and comes back "Missing
    /// required integer field: pid". Combined with not reading `isError`, it
    /// meant every call reported success and did nothing at all: the phone
    /// said `Type "hello"` while not a character was typed.
    public static func requestBody(tool: String, arguments: [String: Any]) -> [String: Any] {
        ["method": "call", "name": tool, "args": arguments]
    }

    /// Whether a reply is a tool refusal wearing a successful envelope.
    public static func isToolError(_ result: [String: Any]) -> Bool {
        result["isError"] as? Bool == true
    }

    /// The human-readable line a tool returns alongside its structured data.
    public static func toolMessage(_ result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// One request, one newline-terminated reply.
    private func send(_ line: Data, timeout: TimeInterval) async throws -> Data {
        let path = Self.socketPath()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(throwing: Failure("Could not open a socket to Cua Driver"))
                    return
                }
                defer { close(fd) }

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let maxPath = MemoryLayout.size(ofValue: address.sun_path)
                guard path.utf8.count < maxPath else {
                    continuation.resume(throwing: Failure("Cua Driver socket path is too long"))
                    return
                }
                withUnsafeMutablePointer(to: &address.sun_path) { raw in
                    raw.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                        _ = strcpy(dst, path)
                    }
                }
                var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else {
                    continuation.resume(throwing: Failure("Cua Driver is not listening"))
                    return
                }

                var payload = line
                payload.append(0x0A)
                let written: Int = payload.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress, buffer.count)
                }
                guard written == payload.count else {
                    continuation.resume(throwing: Failure("Short write to Cua Driver"))
                    return
                }

                // Replies are one line, but a window tree is large enough to
                // arrive in many chunks, so read until the newline.
                var out = Data()
                var chunk = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = Darwin.read(fd, &chunk, chunk.count)
                    if n > 0 {
                        out.append(contentsOf: chunk[0..<n])
                        if out.last == 0x0A { break }
                    } else if n == 0 {
                        break
                    } else {
                        continuation.resume(throwing: Failure("Cua Driver stopped replying"))
                        return
                    }
                }
                continuation.resume(returning: out)
            }
        }
    }

    // MARK: - Process plumbing

    private func run(_ binary: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do { try task.run() } catch {
            throw Failure("Could not run cua-driver: \(error.localizedDescription)")
        }

        // Read on a background thread. Draining the pipe is what stops a
        // chatty tool from filling the 64K buffer and deadlocking the child.
        let handle = pipe.fileHandleForReading
        let collected = Task.detached(priority: .utility) { () -> Data in
            (try? handle.readToEnd()) ?? Data()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if task.isRunning {
            task.terminate()
            _ = await collected.value
            throw Failure("cua-driver \(arguments.first ?? "") timed out after \(Int(timeout))s")
        }

        let data = await collected.value
        return String(decoding: data, as: UTF8.self)
    }

    private static func which(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let fm = FileManager.default
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Cua Driver returned nothing" }
        return String(trimmed.split(separator: "\n").first ?? "")
    }
}
