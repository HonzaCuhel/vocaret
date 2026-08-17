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
# Regenerate the icon if it is missing (scripts/make_icon.swift is the source).
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "==> Generating app icon"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    swift scripts/make_icon.swift "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing. An Apple Development identity is used automatically when present:
# its designated requirement is team-ID based and therefore STABLE across
# rebuilds, so macOS keeps your Accessibility / Microphone / System Audio
# grants. The first signing pops a keychain dialog — click "Always Allow".
# Ad-hoc signing (JUSTSAYIT_ADHOC=1, or no identity available) works too, but
# every rebuild then counts as a brand-new app and permissions reset.
if [[ "${JUSTSAYIT_ADHOC:-0}" == "1" ]]; then
    IDENTITY=""
else
    IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 -oE '"Apple Development: [^"]+"' | tr -d '"' || true)}"
fi
# The designated requirement is what TCC records when you grant Accessibility.
# By default an ad-hoc signature pins it to the exact code hash, so EVERY
# rebuild is a different app and the permission silently stops applying.
# Pinning it to the bundle identifier instead keeps grants across rebuilds.
REQUIREMENT='designated => identifier "com.jancuhel.justsayit"'

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --timestamp=none --identifier com.jancuhel.justsayit \
        -r="$REQUIREMENT" --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing with a stable designated requirement"
    codesign --force --identifier com.jancuhel.justsayit \
        -r="$REQUIREMENT" --sign - "$APP"
fi
echo "==> Designated requirement: $(codesign -d -r- "$APP" 2>&1 | grep -m1 'designated' || echo '(none)')"
codesign --verify --deep "$APP"
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # pkill, not osascript: AppleScript "quit app" needs Automation permission
    # and fails silently without it, leaving the OLD binary running so that
    # `open -a` just re-activates stale code after the install.
    pkill -x JustSayIt 2>/dev/null || true
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/JustSayIt.app"
    cp -R "$APP" "$HOME/Applications/JustSayIt.app"
    echo "==> Installed to ~/Applications/JustSayIt.app"
    open -a "$HOME/Applications/JustSayIt.app"
    sleep 3
    if pgrep -x JustSayIt >/dev/null; then
        echo "==> Relaunched (menu-bar icon should be visible)"
    else
        echo "==> WARNING: app did not start — run: open ~/Applications/JustSayIt.app"
    fi
fi
