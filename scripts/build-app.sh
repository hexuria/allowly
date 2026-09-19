#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_DIR="${BUILD_DIR}/Jev.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
RELEASE_BINARY="${PROJECT_DIR}/.build/release/jevd"

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
# Sign with a stable identity. TCC identifies an ad-hoc-signed app by its
# cdhash, which changes on every single build — so an Accessibility grant is
# silently invalidated by the next rebuild, while still appearing enabled in
# System Settings. A Developer ID signature gives a fixed designated
# requirement (identifier + team), so the grant survives rebuilds.
# Override with JEV_SIGN_IDENTITY=... if you want a different certificate.
SIGN_IDENTITY="${JEV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

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
echo "⚠️  If you re-sign Jev.app with a different identity, those grants"
echo "   will be invalidated and must be re-granted."
echo "============================================"
