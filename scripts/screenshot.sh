#!/bin/sh
# Renders docs/screenshot-{light,dark}.png and docs/screenshot-suggestions-{light,dark}.png
# from the real app views, with made-up skills in a demo home folder.
# The capture app has its own bundle ID and home, so your settings and skills stay untouched.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/screenshot/Skillscout Screenshot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$ROOT/docs"
find "$ROOT/Skillscout" -name '*.swift' ! -name SkillscoutApp.swift -print0 |
  xargs -0 swiftc -O -swift-version 6 -parse-as-library -target arm64-apple-macos15.0 \
    "$ROOT/scripts/screenshot.swift" -o "$APP/Contents/MacOS/Screenshot"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Screenshot</string>
  <key>CFBundleIdentifier</key>
  <string>com.thawee.skillscout.screenshot</string>
  <key>CFBundleName</key>
  <string>Skillscout Mod Screenshot</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
open -n "$APP" --args "$ROOT/docs" "$ROOT/build/demo-home" -AppleLocale en_US -AppleLanguages '(en)'
sleep 1
while pgrep -f "Skillscout Screenshot.app/Contents/MacOS" >/dev/null; do sleep 1; done
ls -la "$ROOT"/docs/screenshot*.png
