#!/usr/bin/env python3
"""Turn recorded HID keyboard reports back into the text they would type.

This is the end of the only chain that can prove typing works before anyone
owns a board: Swift builds the keystrokes, the REAL firmware parses them, the
fake board records what it would have put on the bus, and this reads those
bytes back as characters.

Deliberately written from the USB HID Usage Tables rather than from
`HIDKeycodes.swift`. A decoder derived from the encoder agrees with it by
construction and proves nothing; one written independently disagrees when
either is wrong.

    decode-keystrokes.py <reports-file> [expected-ending]

Exits 1 if `expected-ending` is given and the decoded text does not end with
it. Ends-with rather than equals on purpose: other checks in the same run
press keys too, and a test that breaks when an unrelated assertion is added
above it is a test nobody will keep.
"""

import sys

# usage -> (unshifted, shifted), straight from the HID tables.
KEYS = {}
for i, letter in enumerate("abcdefghijklmnopqrstuvwxyz"):
    KEYS[4 + i] = (letter, letter.upper())
for i, (digit, symbol) in enumerate(zip("1234567890", "!@#$%^&*()")):
    KEYS[30 + i] = (digit, symbol)
KEYS[40] = ("\n", "\n")   # return
KEYS[41] = ("\x1b", "\x1b")  # escape
KEYS[42] = ("\b", "\b")   # delete
KEYS[43] = ("\t", "\t")   # tab
KEYS[44] = (" ", " ")
for usage, plain, shifted in [
    (45, "-", "_"), (46, "=", "+"), (47, "[", "{"), (48, "]", "}"),
    (49, "\\", "|"), (51, ";", ":"), (52, "'", '"'), (53, "`", "~"),
    (54, ",", "<"), (55, ".", ">"), (56, "/", "?"),
]:
    KEYS[usage] = (plain, shifted)

SHIFT = 0x02


def decode(path):
    """Every keyboard report with a key down, as characters."""
    out = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 3 or parts[0] != "keyboard":
                continue
            data = [int(b, 16) for b in parts[1:]]
            modifier, keys = data[0], data[2:8]
            for usage in keys:
                if usage == 0:
                    continue
                pair = KEYS.get(usage)
                if pair is None:
                    out.append("<%d>" % usage)
                else:
                    out.append(pair[1] if modifier & SHIFT else pair[0])
    return "".join(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    typed = decode(sys.argv[1])
    print("   the board would have typed: %r" % typed)
    if len(sys.argv) > 2:
        expected = sys.argv[2]
        if not typed.endswith(expected):
            print("   MISMATCH — expected it to end with %r" % expected, file=sys.stderr)
            return 1
        print("   ends with %r — what Swift was asked to type" % expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
