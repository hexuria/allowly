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

        check("direction does not change the deadline",
              HIDBridge.scrollTimeout(notches: -18) == HIDBridge.scrollTimeout(notches: 18))

        return failures
    }
}
