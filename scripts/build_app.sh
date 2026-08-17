#!/bin/bash
# Build Vocaret.app from the SwiftPM package.
# Usage: scripts/build_app.sh [--install]
#   --install  also copy the bundle to ~/Applications (quitting a running copy)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP=build/Vocaret.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Vocaret "$APP/Contents/MacOS/Vocaret"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Regenerate the icon if it is missing (scripts/make_icon.swift is the source).
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "==> Generating app icon"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    swift scripts/make_icon.swift "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# License texts must travel with the binary, not just live in the repo.
cp LICENSE NOTICE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

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
# NOTE ON PERMISSIONS AND SIGNING
#
# An ad-hoc signature pins the designated requirement to the exact code hash,
# so every rebuild is a different app to macOS and your Accessibility /
# Microphone / System Audio grants silently stop applying — you must re-grant.
#
# It is tempting to "fix" this by overriding the designated requirement with
# `-r='designated => identifier "..."'`. DO NOT. That makes the requirement
# satisfiable by ANY bundle claiming the same identifier, so any app on the
# machine could inherit the permissions the user granted to this one.
#
# The correct fix is to sign with a real identity, whose requirement is
# certificate-based and therefore stable across rebuilds:
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build_app.sh --install
# (list yours with: security find-identity -v -p codesigning)
if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --timestamp=none --identifier com.jancuhel.vocaret --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing (permissions must be re-granted after each rebuild;"
    echo "    set CODESIGN_IDENTITY to keep them — see the comment in this script)"
    codesign --force --identifier com.jancuhel.vocaret --sign - "$APP"
fi
codesign --verify --deep "$APP"
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # pkill, not osascript: AppleScript "quit app" needs Automation permission
    # and fails silently without it, leaving the OLD binary running so that
    # `open -a` just re-activates stale code after the install.
    pkill -x Vocaret 2>/dev/null || true
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Vocaret.app"
    cp -R "$APP" "$HOME/Applications/Vocaret.app"
    echo "==> Installed to ~/Applications/Vocaret.app"
    open -a "$HOME/Applications/Vocaret.app"
    sleep 3
    if pgrep -x Vocaret >/dev/null; then
        echo "==> Relaunched (menu-bar icon should be visible)"
    else
        echo "==> WARNING: app did not start — run: open ~/Applications/Vocaret.app"
    fi
fi
