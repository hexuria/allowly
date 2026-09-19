# Jev

Jev is a remote-control system for your Mac. Run an AI agent or app on your Mac that encounters a dialog? Jev detects it, asks whether it can be auto-answered under policy, and if not, sends a notification to your phone. Open the PWA served by your Mac over Tailscale, see the dialog (screenshot + text), and approve, deny, or speak a command. Jev executes it locally under an allowlist.

## What Jev Can and Cannot Do

**Jev can:**
- Remotely control ordinary application dialogs and sheets via the Accessibility API
- Capture screenshots and stream them to your phone
- Record voice commands and execute them under an allowlist
- Auto-answer dialogs using a learned policy model

**Jev cannot:**
- Bypass or interact with macOS TCC consent sheets (rendered by tccd) — these must be handled by you in person via a VNC deep link to macOS Screen Sharing
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
