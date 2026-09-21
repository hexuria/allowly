#!/bin/bash
# Keep Allowly running: at login, after a reboot, and after a crash.
#
# Why this exists: Allowly was started by hand with `open`, so one power cut or
# one macOS auto-update reboot left the Mac unreachable until somebody came
# home and clicked it. That is fine at a desk and useless if you are away for
# a month.
#
# launchd owns the process after this. That means it will also restart Allowly if
# you quit it from the menu bar, which is the trade: reliability while you are
# away costs you the ability to quit it casually. To stop it for real:
#
#     ops/uninstall-launch-agent.sh
#
# Nothing here needs sudo. A LaunchAgent is per-user and runs only while you
# are logged in — which is also its one real limitation, noted at the end.

set -euo pipefail

LABEL="dev.goldcoders.allowly"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/build/Allowly.app/Contents/MacOS/allowlyd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs"

if [ ! -x "$EXEC" ]; then
  echo "No app at $EXEC — run 'make app' first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

# ThrottleInterval, because this volume is not the boot volume: at login the
# app may not be mounted yet. launchd then retries rather than giving up, and
# Allowly starts by itself once the disk is there.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$EXEC</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$LOGDIR/allowly-launchd.out</string>
    <key>StandardErrorPath</key><string>$LOGDIR/allowly-launchd.err</string>
</dict>
</plist>
PLIST

# Whatever is running now was started by hand; launchd should own the only
# copy, or there are two daemons fighting over port 8787.
pkill -f "Allowly.app/Contents/MacOS/allowlyd" 2>/dev/null || true
pkill -f "Jev.app/Contents/MacOS/jevd" 2>/dev/null || true
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID/com.jev.agent" 2>/dev/null || true
sleep 1

launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed $PLIST"
sleep 6
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  PID=$(launchctl print "gui/$UID/$LABEL" | awk '/^\tpid = /{print $3}')
  echo "Running as pid ${PID:-unknown}, and launchd will restart it if it stops."
else
  echo "launchd did not accept the job — see $LOGDIR/allowly-launchd.err" >&2
  exit 1
fi

cat <<'NOTE'

One limitation worth knowing before you travel: a LaunchAgent runs in your
login session, so it starts when you log in — not at the boot screen. If the
Mac reboots while you are away it will sit at the login window with Allowly not
running, and FileVault makes that certain rather than likely.

If you need it to survive an unattended reboot, turn on automatic login
(System Settings > Users & Groups) and accept what that means: anyone with
physical access to the machine is logged in as you.
NOTE
