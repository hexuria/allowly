# Jev

Jev is a remote-control system for your Mac. Run an AI agent or app on your Mac that encounters a dialog? Jev detects it, asks whether it can be auto-answered under policy, and if not, sends a notification to your phone. Open the PWA served by your Mac over Tailscale, see the dialog (screenshot + text), and approve, deny, or speak a command. Jev executes it locally under an allowlist.

## What it looks like on your phone

Every one of these is a real render of the app, not a mock-up.

| | |
|---|---|
| <img src="docs/screenshots/01-system-permission.png" width="260"> | **A macOS privacy prompt.** The one kind jev refuses to touch. Apple only accepts a press on these from real hardware, so jev tells you what is being asked and says plainly that you have to answer it at the Mac. It does not pretend. |
| <img src="docs/screenshots/02-agent-permission.png" width="260"> | **An agent asking permission.** Claude Code wants to run a shell command. Tap an option, or say it. Each option carries the risk jev judged it to be, and "1 more after this" means the queue is shown one card at a time. |
| <img src="docs/screenshots/04-app-dialog.png" width="260"> | **An ordinary app dialog.** Pages wants to know about unsaved changes, with a picture of the dialog so you can see what you are answering. jev never guesses between "Save" and "Don't Save" — an ambiguous match is refused, not resolved. |
| <img src="docs/screenshots/03-generative-form.png" width="260"> | **A form from your Mac, rendered on your phone.** jev reads the fields of the frontmost window and sends their *shape* — a [json-render](https://json-render.dev) Spec — so you fill real inputs with a real keyboard instead of poking at a JPEG. Tap a field and say "type andres". Passwords are typed, never spoken, transcribed or logged. |
| <img src="docs/screenshots/05-numbers.png" width="260"> | **Numbers, for when names are not enough.** Chrome's profile picker offers four buttons all called "Alex"; no amount of saying the name can choose the third. Say "show numbers" and every pressable thing is labelled — then say "6". The badges are drawn on the phone, over its own screenshot, so the Mac looks exactly as it did. |
| <img src="docs/screenshots/06-normal.png" width="260"> | **Nothing waiting.** The ordinary view: a live picture of your Mac at the top, one button at the bottom. Drag the picture to aim the pointer, pinch to zoom, two fingers to scroll — and hold the button to say what you want. Cards appear over this only when something is actually asking. |
| <img src="docs/screenshots/07-settings.png" width="260"> | **Settings.** Hands-free listening, what every gesture does, and — under *Decisions* — who answers what: ask me, let jev answer the safe ones, allow everything except what I blocked, block everything except what I allowed, plus a per-app override for each app that has ever asked. |
| <img src="docs/screenshots/08-send-text.png" width="260"> | **Typing, for the things you must not say out loud.** A password spoken into a phone goes through speech recognition and, if nothing local understood it, a model. This sheet skips both: the text goes to the Mac as keystrokes, and *Secret* keeps it out of the log, the journal and the transcript. |

## What Jev Can and Cannot Do

**Jev can:**
- Remotely control ordinary application dialogs and sheets via the Accessibility API
- Capture screenshots and stream them to your phone
- Record voice commands and execute them under an allowlist
- Auto-answer the safe dialogs (only options rated low risk: Cancel, Deny, Don't Allow, Not Now); everything that grants, sends, deletes or discards is asked

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

## Notifications

Jev signs every push with a VAPID key, and the JWT carries a contact address for
the push service. Apple refuses the whole token if that address is not a real
one — a `403 BadJwtToken`, before it looks at the notification at all — so the
default is `mailto:jev@example.com`, which Apple accepts. `example.com` is a
reserved domain and reaches nobody, which is the honest description of a contact
for a daemon running on your own Mac.

To use a real one, either set `JEV_VAPID_SUBJECT`, or — if you launch `Jev.app`
from Finder, which inherits no shell — write it to a file:

```sh
echo 'mailto:you@your-domain.com' > ~/"Library/Application Support/jev/vapid-subject"
```

It must be a `mailto:` with a real domain or an `https://` URL; anything else is
ignored and the default is used. If notifications stop arriving, open Settings on
the phone: a failed send is reported there and on the banner at the top of the
screen, because a notification that never arrives otherwise looks exactly like
nothing having happened.

