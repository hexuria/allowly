# Allowly Claude Code Integration

This directory contains the integration hook for Claude Code's PermissionRequest mechanism, allowing the Allowly daemon to approve or deny permission requests made by Claude Code.

## Installation

### 1. Copy the hook to your project

The hook script `jev-permission-hook.sh` is installed as part of the jev build and is located at:

```
/path/to/jev/hooks/jev-permission-hook.sh
```

### 2. Register the hook in Claude Code

Edit `~/.claude/settings.json` and add the following under the `"hooks"` key:

```json
{
  "hooks": {
    "permissionRequest": {
      "command": "bash",
      "args": ["/path/to/jev/hooks/jev-permission-hook.sh"]
    }
  }
}
```

(Replace the path with the actual location of the hook on your system.)

### 3. Pair your phone and start the Allowly daemon

The hook requires the Allowly daemon (`allowlyd`) to be running on your Mac with an active pairing token. The daemon writes the token to a 0600 file at `~/Library/Application Support/allowly/pairing-token`, and the hook reads that first, falling back to the Keychain:

- **Service:** `dev.goldcoders.allowly`
- **Account:** `daemon-pairing-token`

See [SETUP.md](../docs/SETUP.md) for the pairing workflow.

## How It Works

When Claude Code needs a permission decision (e.g., to run a bash command or read a file):

1. **Hook receives request** — Claude Code invokes the hook with a JSON permission request on stdin.
2. **Token lookup** — The hook reads the pairing token from `~/Library/Application Support/allowly/pairing-token`, and falls back to the Keychain if that file is unreadable.
3. **POST to daemon** — The hook sends the permission request to `http://127.0.0.1:8787/api/permission` with the token as an `Authorization` header.
4. **Wait for decision** — The daemon evaluates the request against the Allowly Policy and returns a decision (allow, deny, or ask human).
5. **Return response** — The hook emits the decision back to Claude Code.
6. **Claude Code acts** — If denied, Claude Code will fail the operation. If allowed, it proceeds. If "ask human," Claude Code shows an interactive prompt.

## Behavior When Allowly Daemon Is Not Running

If the daemon is not running or does not respond within 6 seconds:

- The hook **emits a deny response** with reason `"allowly daemon not available; falling back to interactive prompt"`.
- Claude Code treats this as a **deny decision** and will **show an interactive prompt** instead of silently allowing or blocking.
- This is the **fail-closed** design: when Allowly is unavailable, the user is always asked, never auto-granted.

## Pairing Token Storage

The daemon pairing token is stored in a 0600 file, with the Keychain as a fallback:

```bash
# To view the token (returns the pairing token)
security find-generic-password -s dev.goldcoders.allowly -a daemon-pairing-token -w

# To manually add a token (rare — normally done during pairing)
security add-generic-password -s dev.goldcoders.allowly -a daemon-pairing-token -w "your-token-here"

# To delete the token (during unpair or reset)
security delete-generic-password -s dev.goldcoders.allowly -a daemon-pairing-token
```

## Troubleshooting

### Hook shows "allowly daemon not available" but daemon is running

- **Check the daemon is listening on loopback:** Run `lsof -i :8787` and verify the daemon is bound to `127.0.0.1`.
- **Check the pairing token:** Run the command above to verify the token is in the Keychain. If empty, re-run the pairing flow.
- **Check the timeout:** The hook waits 6 seconds. If the daemon is slow, increase `TIMEOUT_SECONDS` in the script.

### "No pairing token found in Keychain"

- The phone has not been paired yet, or the pairing was not completed. See [SETUP.md](../docs/SETUP.md) for the pairing flow.
- Run the pairing flow again to store a new token.

### Hook is not being called at all

- Verify the path in `~/.claude/settings.json` is correct.
- Restart Claude Code after updating settings.json.
- Check that the hook is executable: `ls -l /path/to/jev/hooks/jev-permission-hook.sh` should show `-rwx...`.

### Daemon returns "invalid token" or "unauthorized"

- The pairing token has expired or been revoked.
- Re-pair the phone (see [SETUP.md](../docs/SETUP.md)).
- Verify the daemon is using the same token by checking the Keychain.

## Where the token comes from

The daemon writes the pairing token to a `0600` file:

```
~/Library/Application Support/allowly/pairing-token
```

**not** the Keychain — see the comment on `KeychainManager.loadOrCreatePairingToken`
in `Sources/jevd/main.swift`, which explains why. The hook reads the file first and
falls back to the Keychain, so it keeps working if the token ever moves back.

This was one of three reasons the hook had never worked: it read only the Keychain,
found nothing, and fell back to the interactive prompt every time. The other two were
the missing `/api/permission` route and a port mismatch (the hook posted to 8080; the
daemon listens on 8787).

## What the daemon does with a request

1. **Policy first.** If you have set Claude Code to *always* or *never*, it answers in
   about 15ms and no card is raised.
2. Otherwise a **card goes to your phone** — Allow once / Always allow Claude Code / Deny.
3. The route **waits up to 4 seconds** for you, which leaves the hook's 6-second curl a
   margin to write its own answer.
4. If nobody answers in time it **fails closed** (`allow: false`) and Claude Code shows
   its own prompt. The card stays on the phone, so whichever you reach first wins.

## Protocol Details

### Hook Request (from Claude Code)

The hook receives a JSON object with fields describing the permission being requested:

```json
{
  "name": "bash",
  "resource": "/path/to/script",
  "args": ["arg1", "arg2"]
}
```

Fields depend on the permission type (bash, file read, etc.). The hook forwards this entire object to the daemon.

### Hook Response (to Claude Code)

The hook must return a JSON object:

```json
{
  "allow": true,
  "reason": "Policy permits shell commands in /usr/local/bin"
}
```

- **`allow`** (boolean): Whether to grant the permission.
- **`reason`** (string): Human-readable explanation (logged by Claude Code for transparency).

## Security Notes

- The pairing token is the only credential; it must be kept secret.
- The hook communicates over loopback only (127.0.0.1); no network traffic leaves the Mac.
- The daemon verifies the token before executing any action.
- If the token is compromised, delete it from the Keychain and re-pair the phone.
