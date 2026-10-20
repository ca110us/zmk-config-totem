#!/bin/sh
# Builds the app and packs it into build/TotemBattery.dmg, with an Applications
# shortcut so it can be installed by dragging.
set -e
cd "$(dirname "$0")"

./build.sh

STAGING=build/dmg
DMG=build/TotemBattery.dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/TotemBattery.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname TotemBattery -srcfolder "$STAGING" -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

echo "Packed $DMG"
