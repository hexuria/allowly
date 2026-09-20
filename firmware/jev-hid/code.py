# jev HID bridge — CircuitPython firmware for an RP2040 board.
#
# The problem this solves: macOS tags every event with where it came from. A
# CGEvent is tagged synthetic, and a TCC consent sheet ("jev wants to control
# Google Chrome") ignores synthetic events on purpose — otherwise malware could
# approve its own permissions. There is no entitlement that fakes a hardware
# tag; not even Apple's own Screen Sharing has one.
#
# So we stop faking. This board enumerates as a real USB keyboard and a real
# USB mouse. The events it sends ARE hardware events, because nothing is being
# pretended: there is a physical device on the bus producing them.
#
# Install:
#   1. Flash CircuitPython 9.x to the board.
#   2. Copy boot.py and code.py to the CIRCUITPY drive.
#   3. Replug. It appears as a keyboard, a mouse, and /dev/cu.usbmodem*.
#
# boot.py is what declares the absolute-mouse descriptor; it has to run before
# USB comes up, so it cannot live in this file.

import sys
import time

import usb_hid

# The report IDs must match the ones boot.py put in the descriptor.
KEYBOARD_ID = 0x01
MOUSE_ID = 0x02

# Absolute coordinates are reported over the full 16-bit logical range the
# descriptor declares. jev already speaks in normalised 0…1 from the phone, so
# the conversion is one multiply and stays exact at the edges.
ABS_MAX = 32767

BUTTON_LEFT = 0x01
BUTTON_RIGHT = 0x02
BUTTON_MIDDLE = 0x04


def _device(usage):
    for d in usb_hid.devices:
        if d.usage == usage:
            return d
    return None


keyboard = _device(usb_hid.Device.KEYBOARD.usage)
mouse = _device(usb_hid.Device.MOUSE.usage)


def mouse_report(buttons=0, x=0, y=0, wheel=0):
    """buttons, absolute x, absolute y, wheel — matching boot.py's descriptor."""
    x = max(0, min(ABS_MAX, int(x)))
    y = max(0, min(ABS_MAX, int(y)))
    wheel = max(-127, min(127, int(wheel))) & 0xFF
    mouse.send_report(
        bytes([buttons & 0x07, x & 0xFF, (x >> 8) & 0xFF, y & 0xFF, (y >> 8) & 0xFF, wheel])
    )


def keyboard_report(modifier=0, keys=()):
    report = bytearray(8)
    report[0] = modifier & 0xFF
    for i, code in enumerate(keys[:6]):
        report[2 + i] = code & 0xFF
    keyboard.send_report(bytes(report))


def move(x, y):
    mouse_report(0, x, y)


def click(x, y, button=BUTTON_LEFT, count=1):
    for i in range(count):
        # Park the cursor first, then press. Sending position and button in one
        # report makes some targets see the press at the previous position.
        mouse_report(0, x, y)
        time.sleep(0.012)
        mouse_report(button, x, y)
        time.sleep(0.030)
        mouse_report(0, x, y)
        if i + 1 < count:
            # Inside the double-click interval macOS expects, but not so tight
            # that the two land as one.
            time.sleep(0.070)


def drag(x0, y0, x1, y1, steps=12):
    mouse_report(0, x0, y0)
    time.sleep(0.012)
    mouse_report(BUTTON_LEFT, x0, y0)
    time.sleep(0.030)
    for i in range(1, steps + 1):
        mouse_report(BUTTON_LEFT, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
        time.sleep(0.008)
    mouse_report(0, x1, y1)


def scroll(x, y, amount):
    step = 1 if amount > 0 else -1
    for _ in range(min(40, abs(int(amount)))):
        mouse_report(0, x, y, step)
        time.sleep(0.010)


def keys(modifier, codes):
    keyboard_report(modifier, codes)
    time.sleep(0.020)
    keyboard_report(0, ())


def handle(line):
    """One command per line. Deliberately boring and positional.

    MOVE x y
    CLICK x y button count
    DRAG x0 y0 x1 y1
    SCROLL x y amount
    KEY modifier code[,code...]
    PING
    """
    parts = line.strip().split()
    if not parts:
        return None
    verb = parts[0].upper()
    try:
        if verb == "PING":
            return "PONG jev-hid 1"
        if verb == "MOVE":
            move(int(parts[1]), int(parts[2]))
            return "OK"
        if verb == "CLICK":
            button = int(parts[3]) if len(parts) > 3 else BUTTON_LEFT
            count = int(parts[4]) if len(parts) > 4 else 1
            click(int(parts[1]), int(parts[2]), button, count)
            return "OK"
        if verb == "DRAG":
            drag(int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]))
            return "OK"
        if verb == "SCROLL":
            scroll(int(parts[1]), int(parts[2]), int(parts[3]))
            return "OK"
        if verb == "KEY":
            codes = [int(c) for c in parts[2].split(",")] if len(parts) > 2 else []
            keys(int(parts[1]), codes)
            return "OK"
    except (IndexError, ValueError) as error:
        return "ERR bad arguments: %s" % (error,)
    return "ERR unknown command %s" % (verb,)


print("jev-hid ready")

buffer = ""
while True:
    chunk = sys.stdin.read(1)
    if not chunk:
        continue
    if chunk in ("\n", "\r"):
        if buffer:
            reply = handle(buffer)
            if reply:
                print(reply)
            buffer = ""
    else:
        buffer += chunk
        # A line that never ends is a bug on the other side, not a reason to
        # eat all the memory on a microcontroller.
        if len(buffer) > 200:
            print("ERR line too long")
            buffer = ""
