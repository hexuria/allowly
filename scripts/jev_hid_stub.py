"""A fake USB HID layer, so the real firmware can run without a board.

`firmware/jev-hid/code.py` is written for CircuitPython and talks to one
module we do not have on a Mac: `usb_hid`. Everything else in it — the line
parser, the report packing, the click timing — is ordinary Python, and it is
the part that decides whether the pointer lands on the button.

So we supply the missing module. Reports are recorded instead of being sent
down a cable, which means the firmware can be driven and its output asserted
byte for byte. Nothing here re-implements the firmware; that would be two
sources of truth and the copy would drift. The real file is executed.
"""

import os
import sys
import types

FIRMWARE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "firmware", "jev-hid", "code.py",
)

# The line in code.py after which the module stops defining things and starts
# its read loop. Asserted rather than assumed: if the firmware is restructured
# this fails loudly instead of silently testing nothing.
LOOP_MARKER = 'print("jev-hid ready")'

KEYBOARD_USAGE = 0x06
MOUSE_USAGE = 0x02


class FakeDevice:
    """Records what the firmware would have put on the wire."""

    def __init__(self, usage, log):
        self.usage = usage
        self._log = log

    def send_report(self, data):
        self._log.append((self.usage, bytes(data)))


def install(reports=None):
    """Put a fake `usb_hid` in sys.modules. Returns the report log."""
    log = [] if reports is None else reports
    module = types.ModuleType("usb_hid")

    class Device:
        KEYBOARD = types.SimpleNamespace(usage=KEYBOARD_USAGE)
        MOUSE = types.SimpleNamespace(usage=MOUSE_USAGE)

    module.Device = Device
    module.devices = [FakeDevice(KEYBOARD_USAGE, log), FakeDevice(MOUSE_USAGE, log)]
    sys.modules["usb_hid"] = module
    return log


def load_firmware(with_loop=False):
    """Execute the real code.py and hand back its namespace.

    `with_loop=False` stops before the read loop, which is what a unit test
    wants: the functions, without an infinite loop reading stdin.
    """
    with open(FIRMWARE, "r", encoding="utf-8") as handle:
        source = handle.read()
    if not with_loop:
        if LOOP_MARKER not in source:
            raise SystemExit(
                "jev_hid_stub: %r is no longer in code.py — the split between "
                "its definitions and its read loop has moved, and this loader "
                "needs updating rather than quietly testing half a file."
                % LOOP_MARKER
            )
        source = source.split(LOOP_MARKER)[0]
    namespace = {"__name__": "jev_firmware"}
    exec(compile(source, FIRMWARE, "exec"), namespace)  # noqa: S102 — the point
    return namespace


def mouse_reports(log):
    """Just the mouse reports, unpacked into (buttons, x, y, wheel)."""
    out = []
    for usage, data in log:
        if usage != MOUSE_USAGE:
            continue
        buttons = data[0]
        x = data[1] | (data[2] << 8)
        y = data[3] | (data[4] << 8)
        wheel = data[5] - 256 if data[5] > 127 else data[5]
        out.append((buttons, x, y, wheel))
    return out


def keyboard_reports(log):
    """Just the keyboard reports, as (modifier, [keycodes])."""
    return [
        (data[0], [c for c in data[2:8] if c])
        for usage, data in log
        if usage == KEYBOARD_USAGE
    ]
