#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_DIR="${BUILD_DIR}/Jev.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
RELEASE_BINARY="${PROJECT_DIR}/.build/release/jevd"

# Local settings, never committed. See .env.example for the shape.
#
# This exists because signing needs an Apple Team ID, and a team id is
# not a secret — it is in every binary you sign, and `codesign -dv` reads
# it off anything you have shipped — but it does tie a public repo to a
# named Apple Developer account. Keeping it in an untracked file is about
# attribution, not security.
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${PROJECT_DIR}/.env"
    set +a
fi

# Work out whether this build can be signed BEFORE anything is deleted.
#
# This block used to sit beside `codesign`, after the script had already
# removed and rebuilt the bundle — so a machine that could not resolve an
# identity had its working Jev.app destroyed and replaced with an unsigned
# one, and then exited 1. Observed exactly that: a deliberately failing run
# left `codesign --verify` reporting "code has no resources but signature
# indicates they must be present", and took the RUNNING app down with it,
# because replacing a signed binary under a live process makes the kernel
# refuse its next page fault.
#
# Failing here costs nothing.
# Sign with a stable identity. TCC identifies an ad-hoc-signed app by its
# cdhash, which changes on every single build — so an Accessibility grant is
# silently invalidated by the next rebuild, while still appearing enabled in
# System Settings. A Developer ID signature gives a fixed designated
# requirement (identifier + team), so the grant survives rebuilds.
# Override with JEV_SIGN_IDENTITY=... if you want a different certificate.
#
# The TEAM is pinned, because `head -1` is not a choice. On a machine with
# two Developer ID certificates it silently picks whichever the keychain
# lists first; the designated requirement then changes, and the
# Accessibility and Screen Recording grants die while still showing as
# enabled in System Settings -- the exact failure the paragraph above
# describes. docs/SCREEN-MODEL.md explains the constraint.
#
# `APPLE_TEAM_ID` is the name the rest of the Apple world uses — notarytool,
# CI examples and most .env files — so one value can serve every tool that
# needs it. `JEV_TEAM_ID` still works, because the other knobs in this
# project are namespaced that way and somebody may have it set.
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${JEV_TEAM_ID:-}}"
SIGN_IDENTITY="${JEV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | grep "(${APPLE_TEAM_ID})" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

# Stop, rather than quietly ad-hoc signing a machine that HAS a real
# certificate. Falling through here was worse than `head -1`: a developer
# holding a Developer ID for another team used to get a stable signature
# and would now get an ad-hoc one, losing the Accessibility and Screen
# Recording grants on every single rebuild — the exact failure the pin
# was added to prevent, inflicted on the people it was meant to protect.
if [ -z "${SIGN_IDENTITY}" ]; then
  OTHERS=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)
  if [ -z "${APPLE_TEAM_ID}" ] && [ "${OTHERS}" -gt 0 ]; then
    echo ""
    echo "No Apple Team ID is set, and this Mac has ${OTHERS} Developer ID certificate(s)."
    echo ""
    echo "Which one signs the app decides whether its Accessibility and Screen"
    echo "Recording grants survive a rebuild, so this script will not choose for you."
    echo ""
    echo "Put yours in .env at the root of the checkout (it is gitignored):"
    echo "  cp .env.example .env    # then set APPLE_TEAM_ID"
    echo ""
    echo "Your Developer ID certificates:"
    security find-identity -v -p codesigning | grep "Developer ID Application" || true
    exit 1
  fi
  if [ "${OTHERS}" -gt 0 ]; then
    echo ""
    echo "This Mac has ${OTHERS} Developer ID certificate(s), none for team ${APPLE_TEAM_ID}."
    echo ""
    echo "Signing with a different team changes the app's designated requirement,"
    echo "which silently invalidates its Accessibility and Screen Recording grants"
    echo "— they keep showing as enabled in System Settings and stop working."
    echo ""
    echo "Pick deliberately, then build again:"
    echo "  APPLE_TEAM_ID=YOURTEAMID make app   # sign as your own team"
    echo "  JEV_SIGN_IDENTITY=\"Developer ID Application: ...\" make app"
    echo ""
    security find-identity -v -p codesigning | grep "Developer ID Application" || true
    exit 1
  fi
fi

echo "Building Jev.app..."

# Compile first. This script used to only copy whatever binary happened to be
# in .build, so editing a source file and running it shipped the previous
# build — the app started, looked fine, and behaved like the old code.
if [ "${SKIP_SWIFT_BUILD:-0}" != "1" ]; then
    swift build -c release --package-path "${PROJECT_DIR}"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

if [ ! -f "${RELEASE_BINARY}" ]; then
    echo "Error: Release binary not found at ${RELEASE_BINARY}"
    exit 1
fi

cp "${RELEASE_BINARY}" "${MACOS_DIR}/jevd"
chmod +x "${MACOS_DIR}/jevd"

if [ -d "${PROJECT_DIR}/web" ]; then
    # Remove first: `cp -r src dst` copies INTO dst when it already exists,
    # producing Resources/web/web/... and leaving the real app.js stale forever.
    # Every client-side fix silently failed to ship because of this.
    rm -rf "${RESOURCES_DIR}/web"
    cp -R "${PROJECT_DIR}/web" "${RESOURCES_DIR}/web"
fi

# SwiftPM resource bundles. JevWeb ships snapshot.js this way, and nothing
# else copies it: the generated Bundle.module accessor falls back to an
# absolute path inside the build directory, so a missing bundle resolves fine
# on the machine that compiled it and is absent everywhere else. Copying it
# here, plus the launch assertion in WebSelfTest, is what makes that visible.
RESOURCE_BUNDLE_DIR="$(dirname "${RELEASE_BINARY}")"
for bundle in "${RESOURCE_BUNDLE_DIR}"/*.bundle; do
    # An unmatched glob expands to itself, so check rather than rely on nullglob.
    [ -e "${bundle}" ] || continue
    rm -rf "${RESOURCES_DIR}/$(basename "${bundle}")"
    cp -R "${bundle}" "${RESOURCES_DIR}/"
    echo "  bundled $(basename "${bundle}")"
done

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>jevd</string>
	<key>CFBundleIdentifier</key>
	<string>com.jev.agent</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Jev</string>
	<key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Jev records voice commands to send to your Mac.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Jev transcribes voice commands locally on your Mac.</string>
</dict>
</plist>
EOF

echo "Signing Jev.app..."

if [ -n "${SIGN_IDENTITY}" ]; then
  echo "Signing with: ${SIGN_IDENTITY}"
  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none "${APP_DIR}"
else
  echo "WARNING: no Developer ID found; falling back to ad-hoc."
  echo "         Accessibility will need re-granting after every rebuild."
  codesign --force --sign - --options runtime "${APP_DIR}"
fi

echo ""
echo "============================================"
echo "Jev.app built successfully at:"
echo "${APP_DIR}"
echo ""
echo "IMPORTANT: Before running Jev, grant permissions in System Settings:"
echo "  • Accessibility → Jev (required to interact with dialogs)"
echo "  • Screen Recording → Jev (required to capture screenshots)"
echo ""
echo "⚠️  Screen Recording consent is bound to this exact binary, so macOS"
echo "   may ask for it again after ANY rebuild — not only after a change of"
echo "   signing identity, which is the case that wipes the grant outright."
echo "   macOS also re-asks on its own schedule for apps that capture the"
echo "   screen continuously, which Jev does. Neither is a bug."
echo "============================================"
