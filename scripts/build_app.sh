#!/bin/bash
# Build JustSayIt.app from the SwiftPM package.
# Usage: scripts/build_app.sh [--install]
#   --install  also copy the bundle to ~/Applications (quitting a running copy)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP=build/JustSayIt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/JustSayIt "$APP/Contents/MacOS/JustSayIt"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for a personal app; TCC needs *some* valid signature.
codesign --force --identifier com.jancuhel.justsayit --sign - "$APP"
codesign --verify --deep "$APP"
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "JustSayIt"' 2>/dev/null || true
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/JustSayIt.app"
    cp -R "$APP" "$HOME/Applications/JustSayIt.app"
    echo "==> Installed to ~/Applications/JustSayIt.app"
    echo "    Launch it with: open ~/Applications/JustSayIt.app"
fi
