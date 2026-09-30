#!/bin/bash
# Fast rebuild + install with stable codesigning (preserves Mic/AX permissions).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Sinthex Flow.app"
OLD="/Applications/Flow.app"
STAGE="$ROOT/dist/Sinthex Flow.app"

echo "Baue Sinthex Flow…"
IDENTITY="$("$ROOT/scripts/build_app.sh" | tail -1)"
echo "Signiert mit: $IDENTITY"

osascript -e 'tell application id "de.sinthex.flow" to quit' >/dev/null 2>&1 || true
pkill -f "/Applications/(Sinthex )?Flow.app/Contents/MacOS/" >/dev/null 2>&1 || true
sleep 0.4

rm -rf "$APP" "$OLD"
ditto "$STAGE" "$APP"

codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier' || true
echo "Installiert: $APP"
open "$APP"
