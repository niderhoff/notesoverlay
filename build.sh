#!/bin/zsh
# Builds NotesOverlay with SwiftPM and wraps it in an ad-hoc-signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/NotesOverlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotesOverlay "$APP/Contents/MacOS/NotesOverlay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"

echo "Built $APP"
