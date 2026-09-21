#!/usr/bin/env python3
"""Drive the real firmware with no board attached, and check what it emits.

The firmware decides where the pointer lands and which button goes down.
Until now none of that was checked anywhere: the Swift side asserts the
strings it sends, and the firmware asserts nothing at all, so a wrong byte
order in a mouse report would be discovered by buying hardware and watching
the cursor go to the wrong corner.

Everything here runs the actual `firmware/jev-hid/code.py`. See jev_hid_stub.
"""

import sys

import jev_hid_stub as stub

FAILURES = []


def check(name, condition):
    if not condition:
        FAILURES.append(name)


def fresh():
    """A firmware namespace with an empty report log."""
    log = stub.install([])
    return stub.load_firmware(), log


def main():
    firmware, log = fresh()
    handle = firmware["handle"]

    # ---- The handshake the Mac's HIDBridge insists on ----
    check("PING answers with the banner HIDBridge looks for",
          handle("PING") == "PONG jev-hid 1")

    # ---- Report packing: the bytes themselves ----
    #
    # x and y are 16 bits each, little-endian, over 0…32767. Get the order
    # wrong and every click lands somewhere else entirely.
    log.clear()
    handle("MOVE 16384 9001")
    reports = stub.mouse_reports(log)
    check("a move sends exactly one report", len(reports) == 1)
    check("a move carries the position and no buttons",
          reports[0] == (0, 16384, 9001, 0))

    log.clear()
    handle("MOVE 99999 -500")
    reports = stub.mouse_reports(log)
    check("beyond the right edge clamps to full scale, it does not wrap",
          reports[0][1] == 32767)
    check("a negative coordinate clamps to zero, it does not wrap to 32767",
          reports[0][2] == 0)

    # ---- A click is three reports, and the position comes FIRST ----
    #
    # The firmware parks the pointer, then presses, then releases. Sending
    # position and button together makes some targets see the press at the
    # previous position — which on a permission box means clicking whatever
    # was under the pointer a moment ago.
    log.clear()
    check("a click is acknowledged", handle("CLICK 100 200 1 1") == "OK")
    reports = stub.mouse_reports(log)
    check("a single click is park, press, release", len(reports) == 3)
    check("the pointer is parked with no button down", reports[0] == (0, 100, 200, 0))
    check("the press happens at the same point", reports[1] == (1, 100, 200, 0))
    check("the button is released at the same point", reports[2] == (0, 100, 200, 0))

    log.clear()
    handle("CLICK 10 20 2 1")
    check("button 2 is the right button, matching Swift's Button.right",
          stub.mouse_reports(log)[1][0] == 2)
    log.clear()
    handle("CLICK 10 20 4 1")
    check("button 4 is the middle button, matching Swift's Button.middle",
          stub.mouse_reports(log)[1][0] == 4)

    log.clear()
    handle("CLICK 10 20 1 2")
    check("a double click is six reports", len(stub.mouse_reports(log)) == 6)

    # ---- The exact strings the Swift side builds ----
    #
    # Copied deliberately from HIDBridgeSelfTest.swift rather than generated,
    # so the two languages are pinned to one another. If either side changes
    # its mind about argument order, one of these two files fails.
    for line in ["MOVE 16384 9001",
                 "CLICK 16384 9001 1 1",
                 "CLICK 16384 9001 2 1",
                 "CLICK 16384 9001 4 1",
                 "CLICK 16384 9001 1 2",
                 "DRAG 1 2 3 4",
                 "SCROLL 16384 9001 -7",
                 "KEY 8 4,5",
                 "KEY 0 0"]:
        log.clear()
        check("the firmware accepts what Swift sends: %s" % line,
              handle(line) == "OK")

    # ---- Drag: press, interpolate, release ----
    log.clear()
    handle("DRAG 0 0 1200 600")
    reports = stub.mouse_reports(log)
    check("a drag ends with the button up", reports[-1][0] == 0)
    check("a drag ends where it was asked to", reports[-1][1:3] == (1200, 600))
    check("a drag holds the button down through the middle",
          all(r[0] == 1 for r in reports[2:-1]))
    check("a drag interpolates rather than jumping", len(reports) > 5)

    # ---- Scroll: sign is direction, and the work is capped ----
    log.clear()
    handle("SCROLL 5 5 3")
    check("scrolling up sends positive wheel notches",
          all(r[3] == 1 for r in stub.mouse_reports(log)))
    log.clear()
    handle("SCROLL 5 5 -3")
    check("scrolling down sends negative wheel notches",
          all(r[3] == -1 for r in stub.mouse_reports(log)))
    log.clear()
    handle("SCROLL 5 5 4000")
    capped = len(stub.mouse_reports(log))
    check("a huge flick is capped at 40 notches — the number the Mac's "
          "scrollTimeout is calculated from", capped == 40)

    # ---- Keys ----
    log.clear()
    handle("KEY 8 4,5")
    keys = stub.keyboard_reports(log)
    check("a keystroke is press then release", len(keys) == 2)
    check("the modifier and codes go down together", keys[0] == (8, [4, 5]))
    check("everything is let go afterwards, or the key repeats forever",
          keys[1] == (0, []))

    # ---- Refusals must be refusals, not silence ----
    #
    # HIDBridge treats ERR as "the board is answering" and silence as "the
    # board is gone". A command that produced neither would detach working
    # hardware.
    check("an unknown verb is refused out loud",
          handle("WIGGLE 1 2").startswith("ERR"))
    check("missing arguments are refused out loud",
          handle("CLICK").startswith("ERR"))
    check("a non-numeric argument is refused, not crashed on",
          handle("MOVE left down").startswith("ERR"))
    check("a blank line is ignored rather than answered",
          handle("   ") is None)
    check("the verb is case-insensitive", handle("ping") == "PONG jev-hid 1")

    if FAILURES:
        print("firmware: FAIL")
        for name in FAILURES:
            print("  - %s" % name)
        return 1
    print("firmware: pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
