#!/usr/bin/env python3
"""A board that does not exist, on a port that does.

macOS will hand you a pseudo-terminal: a pair of file descriptors where one
end has a real path under /dev and behaves like a serial device. Point jev at
that path with JEV_HID_PORT and it opens it, handshakes over it and writes
mouse commands into it exactly as it would with an RP2040 on a cable.

On the other end we run the REAL firmware — `firmware/jev-hid/code.py`, not a
description of it — with the one module it needs from CircuitPython replaced
by a recorder. So the whole path is exercised: jev's command building, the
port handling, the acknowledgement protocol, the firmware's parser, and the
HID report bytes it would have put on the bus. Everything but the electrons.

    $ python3 scripts/fake-hid-board.py --reports /tmp/reports.log
    /dev/ttys012                 <- hand this to JEV_HID_PORT

Nothing it does can move your pointer: there is no HID device, only a list.
"""

import argparse
import io
import os
import pty
import sys
import threading
import tty

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jev_hid_stub as stub  # noqa: E402


class ReportLog(list):
    """Records in memory and on disk as the reports happen."""

    def __init__(self, path):
        super().__init__()
        self._file = open(path, "w", encoding="utf-8", buffering=1) if path else None

    def append(self, item):
        super().append(item)
        if self._file:
            usage, data = item
            kind = "mouse" if usage == stub.MOUSE_USAGE else "keyboard"
            self._file.write("%s %s\n" % (kind, " ".join("%02x" % b for b in data)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reports", default="",
                        help="file to write each HID report to, as it happens")
    parser.add_argument("--seconds", type=float, default=120,
                        help="exit after this long, so a test cannot leak a process")
    args = parser.parse_args()

    master_fd, slave_fd = pty.openpty()
    # Raw on both ends, or the terminal line discipline echoes jev's own
    # commands back at it — and `acknowledgement` would read jev's word "OK"
    # inside its own echoed command before the firmware had done anything.
    tty.setraw(master_fd)
    tty.setraw(slave_fd)

    path = os.ttyname(slave_fd)
    # Before stdout is rebound to the pty, and flushed, because whoever
    # launched us is blocking on this line.
    print(path, flush=True)

    log = ReportLog(args.reports)
    stub.install(log)

    # A hard stop. The firmware's loop never returns, so without this a
    # forgotten board sits on a pty forever.
    threading.Timer(args.seconds, lambda: os._exit(0)).start()

    # The firmware reads with sys.stdin.read(1) and replies with print(), so
    # binding those two to the master end is the whole adaptation. Note we
    # keep `slave_fd` open for the life of the process: if we let it go, jev
    # closing its own descriptor would give the firmware an endless EOF and
    # spin a core.
    sys.stdin = io.TextIOWrapper(io.FileIO(master_fd, "r"), encoding="utf-8",
                                 errors="replace", line_buffering=False)
    sys.stdout = io.TextIOWrapper(io.FileIO(os.dup(master_fd), "w"), encoding="utf-8",
                                  errors="replace", line_buffering=True)
    try:
        stub.load_firmware(with_loop=True)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
