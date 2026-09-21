#!/bin/bash
# Stop launchd owning Allowly, and stop Allowly.
#
# The install sets KeepAlive, so quitting from the menu bar only makes
# launchd start it again. This is how you actually stop it.

set -euo pipefail
LABEL="dev.goldcoders.allowly"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_LABEL="com.jev.agent"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$LEGACY_PLIST"
pkill -f "Allowly.app/Contents/MacOS/allowlyd" 2>/dev/null || true
pkill -f "Jev.app/Contents/MacOS/jevd" 2>/dev/null || true
echo "Removed $PLIST — Allowly is stopped and will not come back on its own."
echo "Start it by hand again with: open build/Allowly.app"
