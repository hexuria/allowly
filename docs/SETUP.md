# jev Setup Guide

This guide walks through a one-time, in-person setup to get jev running on your Mac and paired with your phone.

## Prerequisites

- macOS 14+ on Apple Silicon
- iPhone/iPad on iOS 16.4+ (for Web Push notifications)
- Mac is already on a Tailscale tailnet (see "Add phone to tailnet" below)
- Swift 6.3.3 (via Command Line Tools, not Xcode)

## 1. Build and Install jev

### Clone and build

```bash
cd /path/to/jev
make build
```

This compiles a release binary (`jevd`) in `.build/release/`.

### Create the app bundle

```bash
make app
```

This runs `scripts/build-app.sh`, which:
- Creates `Jev.app/Contents/{MacOS/jevd, Resources/web}` with a proper Info.plist
- Bundles the web PWA assets from the `web/` directory
- Ad-hoc codesigns the app with runtime entitlements (Accessibility, Screen Recording)
- Moves `Jev.app` to `/Applications/`

The app is **not signed by Apple**, only by your Mac (ad-hoc signature). This is normal for personal tools.

## 2. Grant Permissions to Jev.app

The first time you run `jevd`, it checks for Accessibility and Screen Recording permissions. If they are missing, it prints instructions to open System Settings.

### Accessibility Permission

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Look for **Jev** in the list
3. If not present, click **+** and navigate to `/Applications/Jev.app` → select it
4. Toggle **Jev** to **ON**

Or use the direct URL:
```
open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
```

### Screen Recording Permission

1. Open **System Settings** → **Privacy & Security** → **Screen Recording**
2. Look for **Jev** in the list
3. If not present, click **+** and navigate to `/Applications/Jev.app` → select it
4. Toggle **Jev** to **ON**

Or use the direct URL:
```
open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording
```

### Verify Permissions

Run `Jev.app` and check the menu bar; if permissions are granted, the icon will appear without warnings. If missing, the first dialog detected will trigger the System Settings prompt.

## 3. Add Your Phone to the Tailscale Tailnet

Your Mac must be on a tailnet, and your phone must be on the same one. `tailscale status` shows its MagicDNS name.

### On your iPhone/iPad

1. Install the [Tailscale app](https://tailscale.com/download/ios)
2. Sign in with the same account as your Mac
3. Tap **Connect** to join the tailnet
4. Verify you can ping your Mac: open a browser and visit `http://<your-mac-tailnet-ip>:8787` (you will see the PWA or a 404 if jevd is not running)

### On your Mac (optional verification)

```bash
# Check that your Mac is on the tailnet
tailscale status
# Output should show your Mac's tailnet IP (100.x.x.x)
```

## 4. Start jev and Open the PWA

### Launch jevd

```bash
/Applications/Jev.app/Contents/MacOS/jevd
```

Or open it from Finder. The app runs in the menu bar; you should see a small icon (jev logo) in the top-right menu bar.

### Logs

Logs are written to `~/Library/Logs/jev.log` (if available) or to stderr if run from the terminal.

### On your phone, open the PWA

1. Open a browser on your phone (Safari, Chrome)
2. Navigate to `http://<your-mac-tailnet-ip>:8787`
3. You should see the jev PWA (a simple interface with "Pending approvals" and a pairing section)

**Do not use HTTPS yet.** The PWA is served over HTTP on the tailnet; the Tailscale connection is already encrypted.

## 5. Pair Your Phone

### First-time pairing flow

1. On the PWA (in the browser), you should see a **"Pair device"** section
2. Tap **Generate pairing code** — a 6-digit code appears
3. On your Mac, a system notification or modal will ask to confirm the pairing; it will show the same 6-digit code
4. Tap **Confirm** on the Mac
5. The PWA refreshes; you should now see **"Paired"** and a **"Add to Home Screen"** prompt

### If pairing hangs or fails

- Ensure your phone and Mac are on the same Tailscale tailnet
- Check the Mac's logs: `tail -f ~/Library/Logs/jev.log` (or stderr if running in terminal)
- Verify jevd is running: check the menu bar or `ps aux | grep jevd`
- Restart jevd and try pairing again

## 6. Add PWA to Home Screen and Enable Notifications

Once paired, the PWA prompts you to add it to the Home Screen. This is **required** for iOS Web Push notifications to work.

### Add to Home Screen (iOS)

1. On the PWA page, tap the **"Add to Home Screen"** button (or use Safari's Share menu → Add to Home Screen)
2. Name it "jev" (or your choice)
3. Tap **Add**
4. The PWA now appears as an app icon on your home screen

### Enable Web Push Notifications

1. When you first tap the Home Screen app, you may be prompted for notification permission
2. Tap **Allow**
3. If prompted later, go to **Settings** → **Notifications** → find the jev PWA app and ensure **Allow Notifications** is **ON**

Once enabled, when a dialog appears on your Mac, you will receive a notification on your phone, even if the PWA is not open.

## What jev Cannot Do

### TCC Consent Sheets

jev **cannot automatically answer** macOS TCC consent sheets (certificate trust, location access, microphone, camera, Full Disk Access, etc.). These are rendered by the system `tccd` process and explicitly reject synthetic input (CGEvent, AXPress, virtual HID).

**What happens instead:** jev detects the TCC sheet, marks it `handoffOnly: true`, and shows you on the phone what is being asked and by which app — with no button, because no button would work. Screen Sharing does not help here: its VNC server posts the same synthetic events the sheet rejects.

**To stop hitting these while away**, in increasing order of effort: grant the permission once while you are at the Mac; pre-approve the binary with a PPPC configuration profile (Full Disk Access and Accessibility only — Apple reserves camera, microphone and Screen Recording for a human); or attach a USB HID bridge, which produces real hardware events and is the only complete fix. Full explanation: https://claude.ai/artifact/HXvBXAsWSYbgaPUfELMzoL

**Examples of TCC dialogs:**
- "MyApp would like to access your files" (Full Disk Access)
- "Trust this certificate?" (SSL/TLS)
- "Allow Bluetooth to continue?" (Bluetooth pairing)
- "Allow access to Contacts?" (any System Privacy category)

### Full Disk Access

Apps must be granted Full Disk Access explicitly in System Settings. jev itself does not need Full Disk Access (it uses Accessibility to drive dialog buttons). However, if you want Claude Code or another tool to run with Full Disk Access, you must grant it manually in System Settings once; jev cannot do this for you, and neither can any tool.

**What to do:**
1. In System Settings → **Privacy & Security** → **Full Disk Access**
2. Click **+** and add the app (e.g., `/Applications/Jev.app`)
3. Toggle it **ON**

The app retains Full Disk Access until you revoke it or re-sign the binary.

## Troubleshooting

### "Accessibility is not trusted" — jev cannot detect dialogs

**Symptom:** Dialogs appear, but jev does not detect them or offer an approval.

**Fix:**
1. Open System Settings → **Privacy & Security** → **Accessibility**
2. Remove **Jev** (select it and click **−**)
3. Restart jevd
4. jevd will prompt you to grant Accessibility again
5. Grant it
6. Restart jevd

**Why this works:** Sometimes the permission is revoked (e.g., after re-signing). Removing and re-adding clears any stale state.

### "No tailnet address found" — phone cannot reach Mac

**Symptom:** Phone shows "Cannot connect to jev daemon" or a connection timeout.

**Fix:**
1. Verify Tailscale is connected on both devices: `tailscale status` on Mac
2. On phone, check Tailscale app shows **Connected** (blue toggle)
3. Test connectivity: on phone, open browser and visit `http://<your-mac-tailnet-ip>:8787`
4. If timeout, check Mac firewall: System Settings → **Privacy & Security** → **Firewall** → verify it allows local network traffic
5. Restart Tailscale on both devices

### Notifications not arriving on phone

**Symptom:** PWA is open and paired, but no notifications appear when dialogs open.

**Likely causes:**
1. **PWA not on Home Screen:** Web Push only works for Home Screen apps on iOS. Add it to Home Screen first.
2. **Notifications disabled:** Check Settings → **Notifications** → jev PWA app is **ON**
3. **PWA not paired:** Verify the PWA shows "Paired" and not "Pairing..."
4. **Phone offline:** If phone loses Tailscale connection, jevd cannot push notifications

**Fix:**
1. Ensure PWA is on Home Screen
2. Ensure notifications are enabled in Settings
3. Ensure Tailscale is connected on phone
4. Restart the PWA (close and re-open from Home Screen)
5. Restart jevd on Mac

### Permissions invalidated after re-signing or update

**Symptom:** After rebuilding jev or running `make app` again, Accessibility/Screen Recording permissions are gone.

**Why:** `make app` ad-hoc codesigns the binary. macOS considers it a new app, so permissions are cleared.

**Fix:**
1. Re-grant Accessibility and Screen Recording (see "Grant Permissions" above)
2. Or, preserve the signature: do not rebuild unless necessary. Save `.app` and backup its signature if you want to modify the binary without re-signing.

### "No pairing token in Keychain" — Claude Code hook fails

**Symptom:** Claude Code prompt shows "jev daemon not available; falling back to interactive prompt."

**Cause:** Pairing was never completed, or the token was deleted.

**Fix:**
1. Pair the phone again (see "Pair Your Phone" above)
2. Verify token is in Keychain:
   ```bash
   security find-generic-password -s com.jev.agent -a daemon-pairing-token -w
   ```
3. If empty, re-run pairing and confirm the pairing code on the Mac

---

For questions or issues beyond this guide, check the logs: `tail -f ~/Library/Logs/jev.log` on the Mac and open the browser console on the phone (Safari → Develop → [device name] → [jev PWA]).
