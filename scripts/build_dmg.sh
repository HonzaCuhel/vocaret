#!/bin/bash
# Build a drag-to-Applications installer. Set JUSTSAYIT_ADHOC=1 for local signing.
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=0
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --version) RELEASE_VERSION="${2:?Missing version}"; shift 2 ;;
        *) echo "Usage: $0 [--skip-build] [--version VERSION]" >&2; exit 2 ;;
    esac
done
if [[ ! "$RELEASE_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "Invalid release version" >&2
    exit 2
fi
if [[ "$SKIP_BUILD" == 0 ]]; then ./scripts/build_app.sh; fi
APP="build/Vocaret.app"
codesign --verify --deep --strict "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/Vocaret" | tr ' ' '-')"
DMG="build/Vocaret-${RELEASE_VERSION}-macOS-${ARCH}.dmg"
if [[ -e "$DMG" ]]; then
    echo "Refusing to overwrite $DMG" >&2
    exit 1
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/vocaret-dmg.XXXXXX")"
trap 'rm -r "$STAGING"' EXIT
ditto "$APP" "$STAGING/Vocaret.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/READ ME.txt" <<'INSTALL'
Vocaret for macOS 14.4 or later

Drag Vocaret.app into Applications, then open it.

This preview is not notarized. Locally ad-hoc signed builds may require
Microphone, Accessibility, System Audio Recording and Automation permissions
to be granted again. The first local transcription can download a speech model;
leave several GB of free disk space for models and working caches.

For YouTube pause/resume, grant Automation access to the browser and enable
Allow JavaScript from Apple Events in its developer menu.

Chat uses your separately installed and signed-in Codex or Claude CLI account.
Requests include recent chat and Vocaret memory; provider quotas and policies apply.

Source and setup: https://github.com/HonzaCuhel/vocaret
INSTALL
hdiutil create -volname "Vocaret ${RELEASE_VERSION}" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG"
hdiutil verify "$DMG"
(cd build && shasum -a 256 "${DMG##*/}") > "$DMG.sha256"
echo "Created $DMG"
