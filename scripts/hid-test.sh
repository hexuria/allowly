#!/bin/bash
# Test the whole HID path with no hardware.
#
# Two halves:
#   1. The firmware on its own — its parser and its report bytes.
#   2. jev talking to that firmware over a pseudo-terminal, which is a real
#      device path as far as the Mac is concerned.
#
# The second half is the one worth having. It covers the part that cannot be
# checked by reading: that the strings Swift builds are the strings the
# firmware parses, and that a reply comes back the way jev expects.
#
# Nothing here can move your pointer. There is no HID device on either side.

set -u
cd "$(dirname "$0")/.."

REPORTS=$(mktemp -t jev-hid-reports)
BOARD_PID=""
DAEMON_PID=""
cleanup() {
  [ -n "$BOARD_PID" ] && kill "$BOARD_PID" 2>/dev/null
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

echo "== 1/2  the firmware, on its own =="
python3 scripts/test-firmware.py || exit 1

echo
echo "== 2/2  jev against that firmware, over a pseudo-terminal =="
if [ ! -x .build/debug/jevd ]; then
  echo "no .build/debug/jevd — run 'swift build' first" >&2
  exit 1
fi

# The board prints its port and then serves it.
PORTFILE=$(mktemp -t jev-hid-port)
python3 scripts/fake-hid-board.py --reports "$REPORTS" --seconds 90 > "$PORTFILE" &
BOARD_PID=$!
for _ in $(seq 1 50); do
  PORT=$(cat "$PORTFILE")
  [ -n "$PORT" ] && break
  sleep 0.1
done
PORT=$(cat "$PORTFILE")
if [ -z "$PORT" ]; then echo "the fake board never named a port" >&2; exit 1; fi
echo "   fake board on $PORT"

LOG="$HOME/Library/Application Support/jev/jev.log"
BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)

# jevd runs its self-tests at launch; with JEV_HID_PORT set they include the
# end-to-end block. It is a menu-bar app, so we start it, let it get through
# startup, and stop it.
JEV_HID_PORT="$PORT" .build/debug/jevd > /dev/null 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 60); do
  sleep 0.5
  tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | grep -q "self-tests" && break
done
RESULT=$(tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | grep "self-tests" | tail -1)
kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""

if [ -z "$RESULT" ]; then
  echo "   jevd never reported its self-tests" >&2
  exit 1
fi
echo "   $RESULT"

echo
echo "== what the board actually received =="
if [ ! -s "$REPORTS" ]; then
  echo "   NOTHING — jev never reached the board" >&2
  exit 1
fi
awk '{print "   " $0}' "$REPORTS" | head -8
echo "   ... $(wc -l < "$REPORTS" | tr -d ' ') HID reports in total"

case "$RESULT" in
  *FAIL*) exit 1 ;;
esac
echo
echo "PASS — the whole path works without hardware."
