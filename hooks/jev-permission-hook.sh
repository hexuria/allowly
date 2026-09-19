#!/bin/bash

# jev-permission-hook.sh — Claude Code PermissionRequest integration
#
# HOW TO REGISTER:
#
# In ~/.claude/settings.json, add under "hooks":
#
#   "hooks": {
#     "permissionRequest": {
#       "command": "bash",
#       "args": ["/absolute/path/to/jev-permission-hook.sh"]
#     }
#   }
#
# The hook runs whenever Claude Code needs a permission (file read, bash command, etc).
# stdin receives JSON like:
#   { "name": "bash", "resource": "/path/to/file", ... }
#
# Waits for jev daemon decision and returns JSON:
#   { "allow": true/false, "reason": "..." }
#
# If daemon is not running or times out, returns the fallback response to let
# Claude Code prompt interactively (fail closed).

set -e

# Configuration
DAEMON_HOST="127.0.0.1"
DAEMON_PORT="8080"
TIMEOUT_SECONDS=5
ENDPOINT="/api/permission"

# Paths
KEYCHAIN_SERVICE="com.jev.agent"
KEYCHAIN_KEY="daemon-pairing-token"

# Colors for logging (to stderr, never stdout)
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_error() {
    echo -e "${RED}[jev-hook ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[jev-hook WARN]${NC} $1" >&2
}

# Retrieve pairing token from macOS Keychain
get_pairing_token() {
    # Use security command to retrieve from Keychain
    security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_KEY" -w 2>/dev/null || echo ""
}

# Read stdin (permission request from Claude Code)
read_request() {
    cat
}

# Send decision request to jev daemon; return response or empty string on error
ask_daemon() {
    local token="$1"
    local request_json="$2"

    # If no token, fail closed by returning askHuman response
    if [[ -z "$token" ]]; then
        log_warn "No pairing token found in Keychain"
        return 1
    fi

    # POST the request to the daemon with timeout
    # curl fails (non-zero exit) on connection error, timeout, or HTTP error status
    local response
    if ! response=$(curl -s -m "$TIMEOUT_SECONDS" \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$request_json" \
        "http://$DAEMON_HOST:$DAEMON_PORT$ENDPOINT" 2>/dev/null); then
        log_warn "Failed to connect to daemon or timeout after ${TIMEOUT_SECONDS}s"
        return 1
    fi

    # Validate response is JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "Daemon returned invalid JSON: $response"
        return 1
    fi

    echo "$response"
}

# Emit the fallback response: ask Claude Code to prompt interactively
fallback_response() {
    # Return response that tells Claude Code to use its normal interactive prompt
    # This is the "fail closed" behavior — no automatic allow
    cat <<EOF
{
  "allow": false,
  "reason": "jev daemon not available; falling back to interactive prompt"
}
EOF
}

# Main
main() {
    local request_json
    request_json=$(read_request)

    local token
    token=$(get_pairing_token)

    local response
    if response=$(ask_daemon "$token" "$request_json"); then
        # Daemon responded; forward its decision
        echo "$response"
    else
        # Daemon error or timeout; emit fallback (non-allow)
        fallback_response
    fi
}

main
