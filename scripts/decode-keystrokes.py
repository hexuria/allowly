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

# usage -> (unshifted, shifted), written out one pair at a time.
#
# Deliberately NOT built with `4 + i` over the alphabet, which is how the
# encoder builds it: a table derived the same way shares any derivation
# mistake and the round trip then proves only that two copies of one error
# agree. Spelled out, the two disagree when either is wrong.
KEYS = {
    4: ("a", "A"), 5: ("b", "B"), 6: ("c", "C"), 7: ("d", "D"), 8: ("e", "E"),
    9: ("f", "F"), 10: ("g", "G"), 11: ("h", "H"), 12: ("i", "I"), 13: ("j", "J"),
    14: ("k", "K"), 15: ("l", "L"), 16: ("m", "M"), 17: ("n", "N"), 18: ("o", "O"),
    19: ("p", "P"), 20: ("q", "Q"), 21: ("r", "R"), 22: ("s", "S"), 23: ("t", "T"),
    24: ("u", "U"), 25: ("v", "V"), 26: ("w", "W"), 27: ("x", "X"), 28: ("y", "Y"),
    29: ("z", "Z"),
    30: ("1", "!"), 31: ("2", "@"), 32: ("3", "#"), 33: ("4", "$"), 34: ("5", "%"),
    35: ("6", "^"), 36: ("7", "&"), 37: ("8", "*"), 38: ("9", "("), 39: ("0", ")"),
}
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
