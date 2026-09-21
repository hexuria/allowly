import Foundation
import JevCore

/// Checks the arithmetic the HID bridge does, and that it stays out of the way
/// when no board is plugged in.
///
/// The mapping is the part worth asserting. An absolute mouse reports a
/// position over a fixed logical range, so an off-by-one at the edges parks the
/// pointer one pixel inside the screen forever — and a wrong scale silently
/// halves every coordinate, which is exactly the class of bug that already bit
/// the Cua backend once.
enum HIDBridgeSelfTest {

    /// Typed by the end-to-end check and decoded back by
    /// `scripts/decode-keystrokes.py`. A capital, a digit and a symbol, so
    /// shift is exercised rather than assumed.
    static let endToEndText = "Hunter2!"

    static func run() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("hid: \(name)") }
        }

        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

        // The corners have to be exact. Anything else and the pointer cannot
        // reach the menu bar or the bottom of the screen.
        let topLeft = HIDBridge.absolute(CGPoint(x: 0, y: 0), in: screen)
        check("top-left is 0,0", topLeft.x == 0 && topLeft.y == 0)

        let bottomRight = HIDBridge.absolute(CGPoint(x: 1800, y: 1169), in: screen)
        check("bottom-right is full scale", bottomRight.x == 32767 && bottomRight.y == 32767)

        let middle = HIDBridge.absolute(CGPoint(x: 900, y: 584.5), in: screen)
        check("centre is half scale",
              abs(middle.x - 16384) <= 1 && abs(middle.y - 16384) <= 1)

        // Off-screen input is clamped, not wrapped. A negative coordinate that
        // wrapped to 32767 would click the opposite corner of the screen.
        let under = HIDBridge.absolute(CGPoint(x: -500, y: -500), in: screen)
        check("negative clamps low", under.x == 0 && under.y == 0)
        let over = HIDBridge.absolute(CGPoint(x: 99_999, y: 99_999), in: screen)
        check("beyond clamps high", over.x == 32767 && over.y == 32767)

        // A display that does not start at the origin still maps from its own
        // corner, or every click on a second monitor is offset by its position.
        let offset = CGRect(x: 1800, y: 0, width: 1800, height: 1169)
        let onSecond = HIDBridge.absolute(CGPoint(x: 1800, y: 0), in: offset)
        check("offset display maps from its own origin", onSecond.x == 0 && onSecond.y == 0)

        // A zero-size display must not divide by zero.
        let degenerate = HIDBridge.absolute(CGPoint(x: 10, y: 10), in: .zero)
        check("zero-size display is survivable", degenerate.x == 0 && degenerate.y == 0)

        // With no board attached nothing is claimed and nothing is sent. This
        // is the state every Mac is in until someone buys the $5 part, so it
        // is the one that must never misbehave.
        if !HIDBridge.isAttached() {
            check("no board means no port", HIDBridge.attachedPort == nil)
            check("no board means send fails", HIDBridge.send("PING") == false)
        }

        // A long scroll gets the time the firmware actually takes.
        //
        // One wheel report per notch with a 10 ms sleep between them, capped
        // at 40 — so a big flick costs 0.4 s in sleeps alone and blew the
        // flat deadline. The board HAD scrolled, so the fallback then
        // scrolled the same screen a second time.
        check("a short scroll keeps the plain deadline",
              HIDBridge.scrollTimeout(notches: 2) < HIDBridge.ackTimeout + 0.05)
        check("a 40-notch scroll outlasts the firmware's own sleeps",
              HIDBridge.scrollTimeout(notches: 40) > 0.40 + HIDBridge.ackTimeout * 0.5)
        check("the deadline is capped with the firmware's cap",
              HIDBridge.scrollTimeout(notches: 4000) == HIDBridge.scrollTimeout(notches: 40))
        // Every command's window against what the firmware actually
        // sleeps. Only `scroll` had an assertion, so the click and drag
        // windows added later were unguarded.
        check("a single click outlasts the firmware's 42 ms",
              HIDBridge.clickTimeout(count: 1) > 0.042)
        check("a double click outlasts its 154 ms",
              HIDBridge.clickTimeout(count: 2) > 0.154)
        check("a drag outlasts its 138 ms", HIDBridge.dragTimeout > 0.138)
        // And keeps outlasting it as the count grows. A window that
        // grows slower than the work is how the scroll double-execution
        // happened; asserting only n=1 and n=2 would let the next edit
        // reintroduce it silently.
        for n in 1...20 {
            let firmware = 0.112 * Double(n) - 0.07
            if HIDBridge.clickTimeout(count: n) <= firmware {
                check("a run of \(n) clicks outlasts the firmware", false)
            }
        }

        // ---- End to end, against a board that does not exist ----
        //
        // Only with an explicit JEV_HID_PORT. Never on a plain launch: if a
        // real board is plugged in, driving it here would jerk the pointer
        // across the screen and click something every time jev started.
        //
        // With `scripts/fake-hid-board.py` on the other end this covers the
        // whole path — connect, handshake, drain, write, acknowledge — and
        // the real firmware parses every command. See that script.
        if let fake = HIDBridge.portOverride {
            let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
            check("the fake board is found at the port it was given",
                  HIDBridge.isAttached() && HIDBridge.attachedPort == fake)
            check("PING is acknowledged", HIDBridge.send("PING"))
            check("a move is acknowledged",
                  HIDBridge.move(to: CGPoint(x: 900, y: 584), in: screen))
            check("a click is acknowledged",
                  HIDBridge.click(at: CGPoint(x: 900, y: 584), in: screen))
            check("a double click is acknowledged",
                  HIDBridge.click(at: CGPoint(x: 10, y: 10), in: screen, count: 2))
            check("a right click is acknowledged",
                  HIDBridge.click(at: CGPoint(x: 10, y: 10), in: screen, button: .right))
            check("a drag is acknowledged",
                  HIDBridge.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 300),
                                 in: screen))
            check("a long scroll finishes inside its own deadline",
                  HIDBridge.scroll(at: CGPoint(x: 900, y: 584), in: screen, amount: 40))
            check("a keystroke is acknowledged", HIDBridge.key(modifier: 8, codes: [4]))
            // The whole point, end to end. `scripts/decode-keystrokes.py`
            // reads the reports the firmware emits and turns them back into
            // text, so the string below has to survive Swift, the wire, the
            // firmware's parser and the HID report packing.
            check("a mixed string types", HIDBridge.type(Self.endToEndText) == .sent)
            // Refused before a single byte goes out, so the caller may safely
            // try another way. A partial send must never report this.
            check("a character with no key sends nothing at all",
                  HIDBridge.type("café") == .nothingSent)
            // A refusal must read as a refusal. Treating it as silence
            // detached a working board and logged that it had.
            check("an unknown command is refused, and the port survives it",
                  HIDBridge.send("WIGGLE 1 2") == false)
            check("the board is still attached after a refusal",
                  HIDBridge.attachedPort == fake)
            check("and still answers afterwards", HIDBridge.send("PING"))
        }

        // ---- Every key jev can name, the board can press ----
        //
        // The whole point of the table. A key present in `Keystrokes` and
        // missing here is a shortcut that silently stops working the moment a
        // board is plugged in, which is the worst time to find out.
        var unreachable: [String] = []
        for (name, code) in Keystrokes.keyCodes where HIDKeycodes.usage[code] == nil {
            unreachable.append("\(name)=\(code)")
        }
        check("every named key has a USB usage (missing: \(unreachable.joined(separator: " ")))",
              unreachable.isEmpty)
        check("no two different keys share a usage",
              Set(HIDKeycodes.usage.values).count == HIDKeycodes.usage.count)

        // Spot-checked against the USB HID Usage Tables, not derived from the
        // same code that produces them — a table that agrees with itself
        // proves nothing.
        check("a is macOS 0 and USB 4", HIDKeycodes.usage[0] == 4)
        check("z is macOS 6 and USB 29", HIDKeycodes.usage[6] == 29)
        check("1 is macOS 18 and USB 30", HIDKeycodes.usage[18] == 30)
        check("0 is macOS 29 and USB 39, not 0", HIDKeycodes.usage[29] == 39)
        check("return is macOS 36 and USB 40", HIDKeycodes.usage[36] == 40)
        check("escape is macOS 53 and USB 41", HIDKeycodes.usage[53] == 41)
        check("tab is macOS 48 and USB 43", HIDKeycodes.usage[48] == 43)
        check("delete is macOS 51 and USB 42", HIDKeycodes.usage[51] == 42)
        check("the arrows are 79..82 and not transposed",
              HIDKeycodes.usage[124] == 79 && HIDKeycodes.usage[123] == 80
                && HIDKeycodes.usage[125] == 81 && HIDKeycodes.usage[126] == 82)
        // macOS numbers 6 before 5 on the number row. Copying the digits in
        // reading order would swap them and nothing else would notice.
        check("5 and 6 are not swapped",
              HIDKeycodes.usage[23] == 34 && HIDKeycodes.usage[22] == 35)

        // ---- Modifiers ----
        check("cmd is 0x08", HIDKeycodes.modifier(from: .maskCommand) == 0x08)
        check("shift is 0x02", HIDKeycodes.modifier(from: .maskShift) == 0x02)
        check("control is 0x01", HIDKeycodes.modifier(from: .maskControl) == 0x01)
        check("option is 0x04", HIDKeycodes.modifier(from: .maskAlternate) == 0x04)
        check("they combine", HIDKeycodes.modifier(from: [.maskCommand, .maskShift]) == 0x0A)
        check("no modifiers is zero, not nil", HIDKeycodes.modifier(from: []) == 0)
        // fn has no USB equivalent. Dropping it silently would turn
        // "fn+left" (start of line) into "left" (one character).
        check("fn refuses rather than being dropped",
              HIDKeycodes.modifier(from: .maskSecondaryFn) == nil)
        check("fn refuses even alongside a real modifier",
              HIDKeycodes.modifier(from: [.maskSecondaryFn, .maskCommand]) == nil)

        // ---- Characters, for typing a password ----
        check("a lowercase letter needs no shift",
              HIDKeycodes.character("a")?.shift == false && HIDKeycodes.character("a")?.usage == 4)
        check("a capital is the same key with shift",
              HIDKeycodes.character("A")?.shift == true && HIDKeycodes.character("A")?.usage == 4)
        check("a digit is the number row", HIDKeycodes.character("7")?.usage == 36)
        check("its symbol is the same key shifted",
              HIDKeycodes.character("&")?.shift == true && HIDKeycodes.character("&")?.usage == 36)
        check("space is 44", HIDKeycodes.character(" ")?.usage == 44)
        check("a symbol that is NOT on the number row still works",
              HIDKeycodes.character("/")?.usage == 56 && HIDKeycodes.character("?")?.shift == true)
        check("every printable ASCII character can be typed",
              (33...126).allSatisfy { HIDKeycodes.character(Character(UnicodeScalar($0)!)) != nil })
        // Refusing is the safe answer: a password typed nearly right looks
        // like it worked.
        check("an accented character is refused, not approximated",
              HIDKeycodes.character("é") == nil)
        check("an emoji is refused", HIDKeycodes.character("🙂") == nil)

        // ---- The layout, which is now asked rather than assumed ----
        //
        // The map comes from UCKeyTranslate, so it is right on any layout. On
        // this Mac it should have been readable; if it ever is not, the US
        // fallback applies and the warning fires.
        check("macOS told us what the keys type",
              HIDKeycodes.liveMap != nil)
        if let live = HIDKeycodes.liveMap {
            check("the live map covers the lowercase alphabet",
                  "abcdefghijklmnopqrstuvwxyz".allSatisfy { live[$0] != nil })
            check("and the digits", "0123456789".allSatisfy { live[$0] != nil })
            check("space, tab and return are there as keys",
                  live[" "]?.usage == 44 && live["\t"]?.usage == 43 && live["\n"]?.usage == 40)
            check("a character is never mapped to usage 0", !live.values.contains { $0.usage == 0 })
        }

        // The near-misses are the whole danger, so they are named.
        //
        // `contains("abc-")` waved through ABC-AZERTY and ABC-QWERTZ — exactly
        // what the check exists to catch — and British was allowed because it
        // shares US letters and digits, which is true and not enough: its
        // shift-2 is " and not @.
        check("a US layout is recognised",
              HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.US"))
        check("ABC counts too", HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.ABC"))
        check("ABC-AZERTY is NOT US-like, however it is spelled",
              !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.ABC-AZERTY"))
        check("nor is ABC-QWERTZ",
              !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.ABC-QWERTZ"))
        check("British is not US-like — its shift-2 is a quote, not an at sign",
              !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.British"))
        check("nor is Irish", !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.Irish"))
        check("AZERTY does not — its A key types q",
              !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.French"))
        check("neither does Dvorak", !HIDKeycodes.looksLikeUSLayout("com.apple.keylayout.Dvorak"))
        check("an unknown layout is treated as not-US", !HIDKeycodes.looksLikeUSLayout(nil))

        // ---- A half-typed password is never retyped ----
        //
        // `type` reports how far it got, because "nothing sent" may be retried
        // another way and "some sent" may not — falling back there would put
        // the first half in twice.
        check("nothing sent is not the same as sent", HIDBridge.Typed.nothingSent != .sent)
        check("partly sent is not nothing sent",
              HIDBridge.Typed.partiallySent(3) != .nothingSent)
        check("partly sent carries how far it got",
              HIDBridge.Typed.partiallySent(3) != .partiallySent(4))

        // ---- The wire, which nothing could check before ----
        //
        // These strings are the contract with firmware/jev-hid/code.py, which
        // parses positionally. Swap two arguments here and every other test in
        // this file still passes; you find out when the hardware arrives and
        // the pointer goes to the wrong place. The expected strings below are
        // written out in full on purpose: they are meant to be read against
        // the firmware's own `handle()`, not derived from the same code that
        // produces them.
        let mid = (x: 16384, y: 9001)
        check("MOVE is verb, x, y",
              HIDBridge.Wire.move(mid) == "MOVE 16384 9001")
        check("CLICK is verb, x, y, button, count",
              HIDBridge.Wire.click(mid, button: .left, count: 1) == "CLICK 16384 9001 1 1")
        check("the right button is 2, as the firmware's BUTTON_RIGHT is",
              HIDBridge.Wire.click(mid, button: .right, count: 1) == "CLICK 16384 9001 2 1")
        check("the middle button is 4, not 3",
              HIDBridge.Wire.click(mid, button: .middle, count: 1) == "CLICK 16384 9001 4 1")
        check("a double click asks for two",
              HIDBridge.Wire.click(mid, button: .left, count: 2) == "CLICK 16384 9001 1 2")
        check("a count below one is still one click, not zero or a crash",
              HIDBridge.Wire.click(mid, button: .left, count: 0) == "CLICK 16384 9001 1 1")
        check("DRAG carries both ends, start first",
              HIDBridge.Wire.drag((x: 1, y: 2), (x: 3, y: 4)) == "DRAG 1 2 3 4")
        check("SCROLL keeps its sign — the firmware decides direction from it",
              HIDBridge.Wire.scroll(mid, amount: -7) == "SCROLL 16384 9001 -7")
        check("KEY joins its codes with commas and no spaces",
              HIDBridge.Wire.key(modifier: 8, codes: [4, 5]) == "KEY 8 4,5")
        check("KEY with nothing held still sends an argument to index",
              HIDBridge.Wire.key(modifier: 0, codes: []) == "KEY 0 0")
        for line in [HIDBridge.Wire.move(mid),
                     HIDBridge.Wire.click(mid, button: .left, count: 2),
                     HIDBridge.Wire.drag(mid, mid),
                     HIDBridge.Wire.scroll(mid, amount: 3),
                     HIDBridge.Wire.key(modifier: 0, codes: [])] {
            check("no command contains a newline, which would split it in two",
                  !line.contains("\n"))
            check("no command is longer than the firmware's 200-byte line limit",
                  line.utf8.count < 200)
        }

        // ---- What the board's answer means ----
        check("silence is not an answer yet", HIDBridge.classify("") == nil)
        check("a partial reply is not an answer yet", HIDBridge.classify("O") == nil)
        check("OK is success", HIDBridge.classify("OK\r\n") == .ok)
        check("PONG is success too — it is what a PING gets back",
              HIDBridge.classify("PONG jev-hid 1\r\n") == .ok)
        check("ERR is a refusal, not silence",
              HIDBridge.classify("ERR unknown command WIGGLE\r\n") == .refused)
        // The ordering that matters: the firmware echoes the verb into its
        // error line, so a buffer holding an error about a verb containing
        // "OK" must still read as a refusal.
        check("an error mentioning a verb with OK in it is still an error",
              HIDBridge.classify("ERR unknown command LOOKUP\r\n") == .refused)
        check("a late OK after an error still reads as the error",
              HIDBridge.classify("ERR bad arguments\r\nOK\r\n") == .refused)

        // ---- Which /dev entries are even candidates ----
        let dev = ["cu.usbmodem1101", "tty.usbmodem1101", "cu.Bluetooth-Incoming-Port",
                   "cu.usbmodem0002", "null", "disk0"]
        let ports = HIDBridge.candidatePorts(in: dev, override: nil)
        check("only cu.usbmodem entries are candidates", ports.count == 2)
        check("tty. is never chosen — it blocks on open waiting for carrier",
              !ports.contains { $0.contains("tty.") })
        check("candidates are full paths", ports.first == "/dev/cu.usbmodem0002")
        check("candidates are sorted, so the choice is not filesystem order",
              ports == ports.sorted())
        check("nothing plugged in is no candidates",
              HIDBridge.candidatePorts(in: ["null"], override: nil).isEmpty)
        check("an override wins outright, so a fake board needs no usbmodem name",
              HIDBridge.candidatePorts(in: dev, override: "/dev/ttys004") == ["/dev/ttys004"])

        // ---- "No room in the buffer" is not "the board is gone" ----
        //
        // This exists because misreading EAGAIN detached a working board
        // mid-swipe. Foundation can hand the same condition back in three
        // shapes, and only the first is obvious.
        check("a POSIX EAGAIN is would-block",
              HIDBridge.isWouldBlock(POSIXError(.EAGAIN)))
        check("an NSError in the POSIX domain is would-block",
              HIDBridge.isWouldBlock(NSError(domain: NSPOSIXErrorDomain,
                                             code: Int(EAGAIN))))
        check("a Cocoa write error WRAPPING EAGAIN is would-block — the shape that bit",
              HIDBridge.isWouldBlock(NSError(
                domain: NSCocoaErrorDomain, code: 512,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                         code: Int(EAGAIN))])))
        check("an unplugged board (ENXIO) is NOT would-block",
              !HIDBridge.isWouldBlock(NSError(domain: NSPOSIXErrorDomain, code: Int(ENXIO))))
        check("a closed descriptor (EBADF) is NOT would-block",
              !HIDBridge.isWouldBlock(POSIXError(.EBADF)))

        check("direction does not change the deadline",
              HIDBridge.scrollTimeout(notches: -18) == HIDBridge.scrollTimeout(notches: 18))

        return failures
    }
}
