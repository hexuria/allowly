# Jev

Jev is a remote-control system for your Mac. Run an AI agent or app on your Mac that encounters a dialog? Jev detects it, asks whether it can be auto-answered under policy, and if not, sends a notification to your phone. Open the PWA served by your Mac over Tailscale, see the dialog (screenshot + text), and approve, deny, or speak a command. Jev executes it locally under an allowlist.

## What Jev Can and Cannot Do

**Jev can:**
- Remotely control ordinary application dialogs and sheets via the Accessibility API
- Capture screenshots and stream them to your phone
- Record voice commands and execute them under an allowlist
- Auto-answer dialogs using a learned policy model

**Jev cannot:**
- Answer macOS TCC consent sheets (rendered by the system, not by the app asking). These reject synthetic input by design, and no remote tool can press them — not jev, not TeamViewer, and almost certainly not Apple's own Screen Sharing, whose VNC server holds `kTCCServicePostEvent` but no HID entitlement, so its clicks are synthetic too. jev detects these, tells you what is being asked, and refuses rather than pretending. To stop hitting them while away: grant the permission once in person, or pre-approve the binary with a PPPC configuration profile (works for Full Disk Access and Accessibility; Apple reserves camera, microphone and Screen Recording for a human). The only complete fix is a USB HID bridge that produces real hardware events.
- Run on macOS versions older than Sonoma (14.0)
- Function without Accessibility and Screen Recording permissions granted in System Settings

## Quickstart

```bash
make build      # swift build -c release
make run        # Run jevd in the terminal
make app        # Bundle Jev.app with proper code signing
make clean      # Clean build artifacts
```

After `make app`, you must grant Accessibility and Screen Recording permissions to Jev.app in System Settings before it will function.

## Setup and Architecture

See [docs/SETUP.md](docs/SETUP.md) for detailed setup instructions and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design of each component.
