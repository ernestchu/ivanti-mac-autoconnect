#!/bin/bash
# Builds, into the ivanti-autoconnect folder:
#   bin/ivanti-signin  the fast sign-in helper ivanti-vpn.sh hands off to (from signin.swift)
#   IvantiVPN.app      the menu bar toggle (from main.swift); it runs ../ivanti-vpn.sh,
#                      so rebuild if you move the folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$ROOT/IvantiVPN.app"
SCRIPT="$ROOT/ivanti-vpn.sh"

HELPER="$ROOT/bin/ivanti-signin"

mkdir -p "$ROOT/bin"
swiftc -O -o "$HELPER" "$HERE/signin.swift"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/IvantiVPN" "$HERE/main.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ivanti-autoconnect.menubar</string>
  <key>CFBundleName</key><string>IvantiVPN</string>
  <key>CFBundleExecutable</key><string>IvantiVPN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Checks and changes the Ivanti Secure Access connection.</string>
  <key>IVScriptPath</key><string>$SCRIPT</string>
</dict></plist>
EOF

# Sign with a real identity when one exists. Ad-hoc signing ties macOS permissions (Accessibility,
# Automation) to the exact build hash, so every rebuild would lose them and the connect run would
# hang waiting on a new permission prompt. Override with SIGN_ID=... if needed.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
  echo "warning: no signing identity found; ad-hoc signing (permissions reset on each rebuild)" >&2
  SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --identifier local.ivanti-autoconnect.signin "$HELPER"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $HELPER"
echo "Built $APP"
