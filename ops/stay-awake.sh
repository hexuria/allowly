#!/bin/bash
# Keep the Mac reachable while you are away. Needs your admin password.
#
# `sleep 1` means the Mac sleeps a minute after you stop touching it, and a
# sleeping Mac is an unreachable Mac. `womp` (wake on network) only answers a
# magic packet from the same network — it will not wake the machine for a
# Tailscale connection from another country.
#
# Only the AC-power profile is touched (-c). On battery everything stays as
# it was, so an unplugged laptop still sleeps and still saves its charge.
#
# Undo with: ops/stay-awake.sh --undo

set -euo pipefail

if [ "${1:-}" = "--undo" ]; then
  echo "Restoring the defaults this script changes (AC power only)…"
  sudo pmset -c sleep 1
  sudo pmset -c autorestart 0
  echo "Done. The Mac will sleep again after a minute on AC."
  exit 0
fi

echo "Setting, on AC power only:"
echo "  sleep 0        never sleep, so the Mac stays reachable"
echo "  autorestart 1  come back by itself after a power cut"
sudo pmset -c sleep 0
sudo pmset -c autorestart 1

echo
pmset -g custom | sed -n '/AC Power/,/Battery/p' | grep -E "^ *(sleep|autorestart|womp)" | sed 's/^ */  /'
cat <<'NOTE'

Two things this does not fix:

  * A LaunchAgent starts at LOGIN, not at boot. After an unattended restart
    the Mac waits at the login window and jev is not running. Automatic login
    (System Settings > Users & Groups) is the only cure, and it means physical
    access to the machine is access to your account.
  * The display is a separate setting and is left alone.
NOTE
