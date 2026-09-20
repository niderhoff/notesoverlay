#!/bin/zsh
# Builds NotesOverlay with SwiftPM and wraps it in an ad-hoc-signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

# Swift 6.4's default build system cannot initialize with the Command Line Tools alone
# ("Could not initialize build system … Unknown error parsing property list");
# fall back to the classic one in that case.
swift build -c release || swift build -c release --build-system native

APP=build/NotesOverlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotesOverlay "$APP/Contents/MacOS/NotesOverlay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"

echo "Built $APP"
