import Foundation
import JevCore

/// A real USB keyboard and mouse on the end of a cable, when one is plugged in.
///
/// Every event macOS delivers carries a tag saying where it came from. Anything
/// posted with `CGEvent` is tagged synthetic, and a TCC consent sheet — "jev
/// wants to control Google Chrome" — ignores synthetic events by design. If it
/// did not, malware could approve its own permissions. There is no entitlement
/// that changes the tag; Apple's own Screen Sharing does not have one either.
///
/// The only way through is to stop faking it. An RP2040 board flashed with the
/// firmware in `firmware/jev-hid/` enumerates as a USB keyboard and an
/// absolute-positioning USB mouse, and talks to us over the CDC serial port on
/// the same cable. Its events are hardware events because there is genuinely a
/// device on the bus producing them.
///
/// When no board is attached this reports `isAttached == false` and every
/// caller falls back to `CGEvent`, which is what jev has always done. The
/// consent-sheet refusal stays exactly as honest as it is today.
///
/// **Pointer only, so far.** `key(modifier:codes:)` below speaks the wire
/// protocol but nothing calls it: `Keystrokes` addresses keys by macOS
/// virtual keycode and the firmware wants USB HID usage IDs, which is a
/// translation table, not a rename. Until that exists, a consent sheet you
/// could answer by clicking is reachable with the board and one that needs
/// Tab or Return is not. Saying otherwise would be the same class of
/// dishonesty this whole file was written to remove.
enum HIDBridge {

    /// Absolute mouse coordinates run over the descriptor's full logical range.
    private static let absoluteMax = 32767.0

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var devicePath: String?
    /// When we last looked and found nothing.
    ///
    /// Without this, every tap and every frame of every swipe re-listed
    /// /dev, opened each `cu.usbmodem*` and waited up to 0.6 s for a reply
    /// that was never coming — so on a Mac with any other serial device
    /// attached, a phone tap stalled for over half a second, forever.
    nonisolated(unsafe) private static var lastEmptyScan: Date?
    private static let rescanAfter: TimeInterval = 10

    // MARK: - Finding the board

    /// Point the bridge at one specific device instead of hunting /dev.
    ///
    /// This exists so the protocol can be exercised without owning the
    /// hardware: `scripts/fake-hid-board.py` opens a pseudo-terminal, runs
    /// the REAL firmware behind it, and hands back a path that looks nothing
    /// like `cu.usbmodem`. Everything below this line then behaves exactly as
    /// it will with a board on the end of a cable.
    static let portOverrideVariable = "ALLOWLY_HID_PORT"

    static var portOverride: String? {
        Allowly.environment("ALLOWLY_HID_PORT", "JEV_HID_PORT")
    }

    /// Serial ports that could be the board. CircuitPython presents its CDC
    /// port as a usbmodem device; `cu.` rather than `tty.` because `tty.`
    /// blocks on open waiting for carrier detect.
    static func candidatePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return candidatePorts(in: names, override: portOverride)
    }

    /// Pure, so the `cu.`-not-`tty.` rule is asserted rather than assumed.
    /// Picking `tty.` would block on open waiting for carrier detect, which
    /// is a hang at startup rather than a wrong answer.
    static func candidatePorts(in names: [String], override: String?) -> [String] {
        if let override { return [override] }
        return names
            .filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    /// Whether a board is attached and answering.
    ///
    /// Answering matters: a usbmodem port could be any number of things, from
    /// an Arduino to a phone. We only treat it as the bridge if it replies to
    /// PING with the firmware's own banner, so jev never starts writing mouse
    /// commands into somebody's 3D printer.
    static func isAttached() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if handle != nil { return true }
        if let last = lastEmptyScan, Date().timeIntervalSince(last) < rescanAfter {
            return false
        }
        let found = connectLocked() != nil
        lastEmptyScan = found ? nil : Date()
        return found
    }

    static var attachedPort: String? {
        lock.lock(); defer { lock.unlock() }
        return devicePath
    }

    @discardableResult
    private static func connectLocked() -> FileHandle? {
        if let handle { return handle }
        for path in candidatePorts() {
            guard let opened = FileHandle(forUpdatingAtPath: path) else { continue }
            // Without this the polling loops below are decoration.
            //
            // `FileHandle(forUpdatingAtPath:)` opens O_RDWR and blocking, so
            // `read(upToCount:)` with nothing to read sits in read(2) forever
            // and the `while Date() < deadline` around it never gets control
            // back. Any usbmodem device that does not answer — an Arduino, a
            // 3D printer, a phone in DFU — then hung jevd at startup, before
            // the menu bar and before the server, because the self-test pings
            // every candidate port. O_NONBLOCK makes an empty read return
            // immediately, which is what the deadline was always assuming.
            let flags = fcntl(opened.fileDescriptor, F_GETFL, 0)
            _ = fcntl(opened.fileDescriptor, F_SETFL, (flags == -1 ? 0 : flags) | O_NONBLOCK)
            if handshake(on: opened) {
                handle = opened
                devicePath = path
                JevLog.write("[allowly] HID bridge attached on \(path)")
                return opened
            }
            try? opened.close()
        }
        return nil
    }

    /// Read whatever is waiting, without blocking and without Foundation.
    ///
    /// `FileHandle.read(upToCount:)` cannot be used on a non-blocking
    /// descriptor. It throws EAGAIN when there is nothing to read, which is
    /// expected — but measured against a port with a reply already sitting in
    /// it, it threw on all 27 attempts across 600 ms while a plain `read(2)`
    /// on the same port returned the answer on the first try.
    ///
    /// Every read in this file went through it, so the handshake could never
    /// complete: `isAttached()` would have been false with a board plugged
    /// in, and the $4 part would have arrived and done nothing. Found by the
    /// fake board in `scripts/fake-hid-board.py`, which is the entire reason
    /// that script exists.
    ///
    /// The write path is left on FileHandle deliberately — it demonstrably
    /// works, and `isWouldBlock` exists to handle its EAGAIN.
    private static func readAvailable(_ handle: FileHandle, max count: Int = 256) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(handle.fileDescriptor, raw.baseAddress, count)
        }
        return read > 0 ? Data(buffer[0..<read]) : Data()
    }

    private static func handshake(on handle: FileHandle) -> Bool {
        guard write("PING", to: handle) else { return false }
        // The board answers in a few milliseconds. Poll rather than block, so a
        // silent device costs a fifth of a second and not the whole command.
        let deadline = Date().addingTimeInterval(0.6)
        var seen = ""
        while Date() < deadline {
            let chunk = readAvailable(handle)
            if !chunk.isEmpty {
                seen += String(decoding: chunk, as: UTF8.self)
                if seen.contains("PONG jev-hid") { return true }
            }
            usleep(20_000)
        }
        return false
    }

    @discardableResult
    private static func write(_ line: String, to handle: FileHandle) -> Bool {
        guard let data = (line + "\n").data(using: .utf8) else { return false }
        // Retry EAGAIN, and only EAGAIN.
        //
        // O_NONBLOCK turned "wait for room in the buffer" into an error, so
        // treating the first throw as failure would detach a perfectly good
        // board mid-swipe and make the next gesture pay for a full rescan
        // and handshake. But an UNPLUGGED board throws EBADF or ENXIO
        // straight away, and waiting 200 ms on that delays detection by a
        // whole command while holding `lock` — which on a swipe means
        // parking a cooperative-pool thread for nothing.
        //
        // Commands are under 40 bytes against a kilobyte of buffer, so the
        // retry only ever fires under a sustained stream.
        let deadline = Date().addingTimeInterval(0.2)
        repeat {
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                // Dig the real errno out. Darwin can surface this as a
                // Cocoa NSFileWriteUnknownError with the POSIX code buried
                // in NSUnderlyingError, and comparing `code` against EAGAIN
                // in that case classifies a perfectly ordinary "buffer
                // full" as fatal — detaching a working board mid-stream,
                // which is the regression this retry exists to prevent.
                guard Self.isWouldBlock(error) else { return false }
                usleep(2_000)
            }
        } while Date() < deadline
        return false
    }

    /// Is this "no room in the buffer yet", under any of the three shapes
    /// Foundation might hand it back in?
    static func isWouldBlock(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .EAGAIN || posix.code == .EWOULDBLOCK
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain,
           ns.code == Int(EAGAIN) || ns.code == Int(EWOULDBLOCK) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isWouldBlock(underlying)
        }
        return false
    }

    /// Forget the port. Called when a write fails, which is what unplugging
    /// looks like from here.
    private static func dropLocked(_ reason: String) {
        if let path = devicePath {
            JevLog.write("[allowly] HID bridge detached from \(path): \(reason)")
        }
        try? handle?.close()
        handle = nil
        devicePath = nil
    }

    // MARK: - Sending

    /// Send one command. Returns false if there is no board or it stopped
    /// answering — the caller then uses CGEvent, so a yanked cable degrades to
    /// the old behaviour instead of dropping the command on the floor.
    @discardableResult
    static func send(_ command: String, timeout: TimeInterval = ackTimeout) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Honour the negative cache here too. `isAttached` consults it and
        // `send` did not, so the one caller that does not gate on
        // `isAttached` first — the startup self-test — paid for a second
        // full scan of /dev immediately after the cached one.
        if handle == nil, let last = lastEmptyScan, Date().timeIntervalSince(last) < rescanAfter {
            return false
        }
        guard let handle = connectLocked() else {
            lastEmptyScan = Date()
            return false
        }
        // Throw away anything still sitting in the port.
        //
        // `acknowledgement` matches over an accumulating buffer, so a late
        // reply to the PREVIOUS command would satisfy this one instantly —
        // and this one might never have been acted on at all.
        drain(handle)
        guard write(command, to: handle) else {
            dropLocked("write failed")
            return false
        }
        // Wait for the board to say it did it.
        //
        // Returning true because the bytes reached the cable is the same
        // mistake as reporting a keystroke delivered: if the firmware has
        // wedged with the port still open, jev would report a click that
        // never happened. The handshake already insists on hearing PONG;
        // every command gets the same treatment.
        // A board that says ERR is a board that is ANSWERING. Treating
        // it as silence detached a working device, forced a full
        // rescan, and logged "detached" about hardware that was fine.
        switch acknowledgement(on: handle, timeout: timeout) {
        case .ok:
            return true
        case .refused:
            JevLog.write("[allowly] HID bridge refused: \(command.prefix(12))")
            return false
        case .silent:
            dropLocked("no acknowledgement")
            return false
        }
    }

    enum Acknowledgement: Sendable { case ok, refused, silent }

    /// What the board has said so far, or nil for "not enough yet".
    ///
    /// Pure, and every line of it is scar tissue:
    ///
    /// - ERR is checked FIRST. The firmware echoes the verb back in its error
    ///   line, so looking for "OK" over an accumulating buffer can match a
    ///   verb that happens to contain those letters.
    /// - PONG counts as OK. The handshake reply is neither, so `send("PING")`
    ///   against a LIVE board returned `.silent` and dropped the port —
    ///   detaching working hardware and logging that it had.
    ///
    /// Both were found by reading, not by testing, because nothing here could
    /// be tested without a board. Now it can.
    static func classify(_ seen: String) -> Acknowledgement? {
        if seen.contains("ERR") { return .refused }
        if seen.contains("OK") || seen.contains("PONG jev-hid") { return .ok }
        return nil
    }

    /// The exact line that goes down the wire.
    ///
    /// Pure and separated out because this is the contract with
    /// `firmware/jev-hid/code.py`, which parses positionally — `parts[1]`,
    /// `parts[2]` — and the only other way to check the two agree is to own
    /// the hardware and watch the pointer move.
    enum Wire {
        static func move(_ p: (x: Int, y: Int)) -> String { "MOVE \(p.x) \(p.y)" }

        static func click(_ p: (x: Int, y: Int), button: Button, count: Int) -> String {
            "CLICK \(p.x) \(p.y) \(button.rawValue) \(max(1, count))"
        }

        static func drag(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int)) -> String {
            "DRAG \(a.x) \(a.y) \(b.x) \(b.y)"
        }

        static func scroll(_ p: (x: Int, y: Int), amount: Int) -> String {
            "SCROLL \(p.x) \(p.y) \(amount)"
        }

        /// An empty key list still sends one argument, because the firmware
        /// indexes `parts[2]` unconditionally.
        static func key(modifier: Int, codes: [Int]) -> String {
            let list = codes.map(String.init).joined(separator: ",")
            return "KEY \(modifier) \(list.isEmpty ? "0" : list)"
        }
    }

    /// How long the board gets to answer an ordinary command.
    ///
    /// A click is two sleeps and a report; a drag is twelve. Everything but
    /// a long scroll finishes well inside this.
    static let ackTimeout: TimeInterval = 0.4

    /// The deadline for a click, scaled by how many the firmware makes.
    /// The firmware costs `112n - 70` ms, so the window is that plus a
    /// constant margin — the same slope, never crossing it at any n.
    ///
    /// The first version allowed `400 + 80n`, which grows SLOWER than
    /// the work and would have crossed at about fifteen clicks. Nothing
    /// sends more than two today, but a window that grows slower than
    /// the work is exactly how the scroll double-execution happened.
    static func clickTimeout(count: Int) -> TimeInterval {
        let n = Double(max(1, count))
        return ackTimeout + (0.112 * n - 0.07) + 0.05
    }

    /// Twelve interpolated steps in the firmware, ~138 ms of sleeps.
    static let dragTimeout: TimeInterval = ackTimeout + 0.2

    /// The deadline for a scroll of `notches`.
    ///
    /// The firmware sends one wheel report per notch with a 10 ms sleep
    /// between them, capped at 40 — so a big flick costs 0.4 s in sleeps
    /// alone and blew the flat deadline. What happened then was worse than a
    /// timeout: the board HAD scrolled, `send` returned false, the port was
    /// dropped, and the CGEvent fallback scrolled the same screen a second
    /// time. Give the work the time the firmware says it takes.
    static func scrollTimeout(notches: Int) -> TimeInterval {
        ackTimeout + 0.012 * Double(min(40, abs(notches)))
    }

    /// Read and discard whatever is waiting, without blocking.
    private static func drain(_ handle: FileHandle) {
        // Bounded. This is the one loop here with no deadline, and it runs
        // holding `lock` — so a board whose firmware is stuck printing
        // would block every pointer command, not just the HID ones. Sixteen
        // reads is 8 KB, far more than any reply this protocol produces.
        for _ in 0..<16 {
            guard !readAvailable(handle, max: 512).isEmpty else { return }
        }
    }

    /// Read until the board answers OK, or give up.
    private static func acknowledgement(on handle: FileHandle,
                                        timeout: TimeInterval = 0.4) -> Acknowledgement {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = ""
        while Date() < deadline {
            let chunk = readAvailable(handle, max: 128)
            if !chunk.isEmpty {
                seen += String(decoding: chunk, as: UTF8.self)
                if let verdict = classify(seen) { return verdict }
            }
            usleep(5_000)
        }
        return .silent
    }

    /// Screen point (top-left origin, in points) to the descriptor's 0…32767.
    ///
    /// Absolute positioning maps to the primary display, which is the same
    /// display `Pointer.displayBounds()` resolves against, so the two agree.
    /// A second monitor needs both revisited together — noted in the issue.
    static func absolute(_ point: CGPoint, in bounds: CGRect) -> (x: Int, y: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let nx = min(1, max(0, (point.x - bounds.minX) / bounds.width))
        let ny = min(1, max(0, (point.y - bounds.minY) / bounds.height))
        return (Int((nx * absoluteMax).rounded()), Int((ny * absoluteMax).rounded()))
    }

    // MARK: - The operations Pointer and Keystrokes need

    static func move(to point: CGPoint, in bounds: CGRect) -> Bool {
        return send(Wire.move(absolute(point, in: bounds)))
    }

    static func click(at point: CGPoint, in bounds: CGRect,
                      button: Button = .left, count: Int = 1) -> Bool {
        let p = absolute(point, in: bounds)
        // Scaled with the work, like scroll. The firmware sleeps 42 ms
        // for one click and 154 ms for a double (2 x 42 plus a 70 ms
        // gap); `clickTimeout` tracks that slope exactly, so nothing
        // can outrun it at any count. A board that is slow once no
        // longer produces what scroll used to: the board acts, the flat
        // ack window lapses, `send` reports false, and CGEvent does it
        // all over again.
        return send(Wire.click(p, button: button, count: count),
                    timeout: clickTimeout(count: count))
    }

    static func drag(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> Bool {
        let a = absolute(start, in: bounds)
        let b = absolute(end, in: bounds)
        // Twelve interpolated steps in the firmware, ~138 ms of sleeps.
        return send(Wire.drag(a, b), timeout: dragTimeout)
    }

    static func scroll(at point: CGPoint, in bounds: CGRect, amount: Int) -> Bool {
        let p = absolute(point, in: bounds)
        return send(Wire.scroll(p, amount: amount), timeout: scrollTimeout(notches: amount))
    }

    static func key(modifier: Int, codes: [Int]) -> Bool {
        return send(Wire.key(modifier: modifier, codes: codes))
    }

    enum Button: Int {
        case left = 1
        case right = 2
        case middle = 4
    }
}
