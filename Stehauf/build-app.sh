#!/bin/bash
# Baut Stehauf.app aus dem Swift-Paket. Braucht nur die Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Stehauf"
APP="build/Stehauf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Stehauf"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc-Signatur: reicht für den eigenen Mac. Nach jedem Neubau fragt macOS
# die Berechtigungen (Bluetooth, Kalender) erneut ab.
codesign --force --sign - "$APP"

echo "Fertig: $(pwd)/$APP"
