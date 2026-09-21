#!/bin/bash
# Stop launchd owning jev, and stop jev.
#
# The install sets KeepAlive, so quitting from the menu bar only makes
# launchd start it again. This is how you actually stop it.

set -euo pipefail
LABEL="com.jev.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "Jev.app/Contents/MacOS/jevd" 2>/dev/null || true
echo "Removed $PLIST — jev is stopped and will not come back on its own."
echo "Start it by hand again with: open build/Jev.app"
