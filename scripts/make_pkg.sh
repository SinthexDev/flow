#!/bin/bash
# Builds the installer for other Macs: dist/Sinthex-Flow-<version>.pkg (installs "/Applications/Sinthex Flow.app")
# plus dist/Sinthex-Flow-<version>.zip (the bare app, for drag-and-drop installs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="Sinthex Flow.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
PKG="$DIST/Sinthex-Flow-$VERSION.pkg"
ZIP="$DIST/Sinthex-Flow-$VERSION.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$ROOT/scripts/build_app.sh" >/dev/null

mkdir -p "$WORK/root/Applications"
# Drop extended attributes (Synology/provenance/quarantine); pkgbuild would ship them as ._ files.
ditto --norsrc --noextattr --noqtn "$DIST/$APP" "$WORK/root/Applications/$APP"
export COPYFILE_DISABLE=1

# Updaters up to 1.9.2 look for a bundle named Flow.app in the expanded package.
# They find this bridge in the scripts, install it and open it; it installs the real app.
BRIDGE="$WORK/scripts/Flow.app"
mkdir -p "$BRIDGE/Contents/MacOS" "$BRIDGE/Contents/Resources"
cp "$ROOT/packaging/scripts/"* "$WORK/scripts/"
cp "$ROOT/packaging/Info.plist" "$BRIDGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Flow' "$BRIDGE/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$BRIDGE/Contents/Resources/AppIcon.icns"
cp "$ROOT/packaging/bridge/Flow" "$BRIDGE/Contents/MacOS/Flow"
chmod +x "$BRIDGE/Contents/MacOS/Flow"
ditto --norsrc --noextattr --noqtn "$WORK/root/Applications/$APP" "$BRIDGE/Contents/Resources/$APP"

# Never relocate into another copy of the bundle (e.g. a synced dist copy) – always /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$WORK/components.plist"

rm -f "$PKG" "$ZIP"
chmod +x "$WORK/scripts/postinstall"
pkgbuild \
  --root "$WORK/root" \
  --component-plist "$WORK/components.plist" \
  --scripts "$WORK/scripts" \
  --identifier "de.sinthex.flow" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG"

ditto -c -k --norsrc --noextattr --noqtn --keepParent "$WORK/root/Applications/$APP" "$ZIP"

echo "Paket: $PKG ($(du -h "$PKG" | cut -f1))"
echo "App-Zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
