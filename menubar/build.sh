#!/bin/bash
# Builds "Ivanti AutoConnect.app" (the menu bar app) into the ivanti-autoconnect folder.
# This is the only command-line step; everything else happens in the app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$ROOT/Ivanti AutoConnect.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/setup"
swiftc -O -o "$APP/Contents/MacOS/IvantiAutoConnect" \
  "$HERE/main.swift" "$HERE/Credentials.swift" "$HERE/Ivanti.swift" "$HERE/SetupWindow.swift"
cp "$ROOT"/setup-totp/*.png "$APP/Contents/Resources/setup/"

# App icon: the menu bar shield, drawn at every size by make-icon.swift.
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$HERE/make-icon.swift" "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ivanti-autoconnect.menubar</string>
  <key>CFBundleName</key><string>Ivanti AutoConnect</string>
  <key>CFBundleDisplayName</key><string>Ivanti AutoConnect</string>
  <key>CFBundleExecutable</key><string>IvantiAutoConnect</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Checks, starts and stops the Ivanti Secure Access connection.</string>
</dict></plist>
EOF

# Sign with a real identity when one exists. Ad-hoc signing ties macOS permissions
# (Accessibility, Automation) and keychain access to the exact build, so every rebuild would ask
# again. Override with SIGN_ID=... if needed.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
  echo "warning: no signing identity found; ad-hoc signing (permissions reset on each rebuild)" >&2
  SIGN_ID="-"
fi
xattr -cr "$APP"   # copied screenshots carry Finder/quarantine attributes that codesign rejects
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP"
