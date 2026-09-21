# Allowly Architecture

Allowly detects dialog boxes on your Mac and asks for human approval when you're away. Only the human decides; no auto-clicks.

## Components

**JevCore** — Domain types and policy layer. Defines ApprovalRequest (a dialog), Decision (allow/deny/askHuman), Command (what to execute), and Policy (which apps/commands are safe).

**JevAX** — Accessibility observer on the Mac. Detects new dialogs via AXObserver, reads their button labels and text, captures screenshots, and presses buttons. Cannot touch TCC consent sheets (macOS blocks synthetic input to tccd system process).

**JevCapture** — Screenshots via ScreenCaptureKit.

**JevServer** — HTTP server bound to loopback only (127.0.0.1:8080). Routes: `/api/pending` (list dialogs), `/api/decide` (receive approval), `/api/command` (execute), `/api/screenshot`, `/api/tap`, `/api/type`, `/api/policy`, `/api/vapid-key` and `/api/subscribe` (web push). Serves the PWA.

**allowlyd** — Menu bar app (`Allowly.app`, bundle id `dev.goldcoders.allowly`). Runs JevAX, JevServer, and the Claude Code hook. One-time onboarding grants Accessibility and Screen Recording.

**web/** — PWA. Displays pending dialogs with screenshot + buttons. Phone user taps approve/deny or speaks a voice command. Paired-device only; must be added to Home Screen for iOS Web Push.

## Request Lifecycle

1. Dialog appears on Mac → JevAX detects via AXObserver
2. Screenshot + button labels sent to ApprovalStore
3. Web Push notification to paired phone
4. User taps phone notification, sees screenshot + buttons
5. User taps Approve/Deny or speaks a command
6. Phone sends decision to `/api/command` with nonce (replay guard)
7. Policy re-evaluates (dangerous buttons escalate to human, unknown apps deny)
8. JevAX executes via AXPress or launches app

**TCC consent sheets** (cert trust, location, microphone, Full Disk Access) honour only events tagged as coming from real hardware. Anything posted through `CGEvent` is tagged synthetic and discarded, including Apple's Screen Sharing. Without a USB board, Allowly marks these `handoffOnly`, surfaces what is being asked, and does not claim to have pressed one. With a USB HID bridge plugged in, the click is hardware and the sheet accepts it.

## Trust Boundaries

**Phone ↔ Server:** Tailscale provides encryption and device isolation. Pairing token stored in phone's localStorage and Mac's Keychain. Nonces prevent replay.

**Policy Evaluation:** Before any action, Policy checks: Is the app in the allowlist? Is the button label dangerous (delete, erase, send, always allow)? Is the risk too high? Unknown apps default to deny.

**Claude Code Integration:** The PermissionRequest hook asks Policy: "Should Claude Code read this file / run this command?" Returns allow/deny/askHuman. Lets Claude Code respect your intent without bypassing the allowlist.

**Phone Limitations:** PWA requires Home Screen addition for Web Push. Voice is push-to-talk only (no background microphone). Audio uploaded to Mac for transcription (no voice leaves your device).

## Why Human Handoff?

Not all dialogs are equally safe. "Save changes?" is low-risk; "Erase disk?" is critical. TCC sheets block synthetic clicks entirely. Malicious apps can show fake dialogs. The policy layer + human escalation keeps fast approvals safe and rare dialogs in the human's hands.
