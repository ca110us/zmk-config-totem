#!/bin/sh
# Builds build/TotemBattery.app. Copy it to /Applications before enabling "Open at Login".
set -e
cd "$(dirname "$0")"

APP=build/TotemBattery.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" \
    -o "$APP/Contents/MacOS/TotemBattery" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
# The iconset stops at 256pt: AppKit decodes the app icon at launch, and the 512pt
# sizes alone add ~6 MB of resident memory. Resources/source has the full vector art.
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $APP"
