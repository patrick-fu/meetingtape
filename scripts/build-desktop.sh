#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Usage: scripts/build-desktop.sh [debug|release]" >&2; exit 1 ;; esac
cd "$ROOT"
./scripts/build-local.sh "$CONFIGURATION"
IDENTITY="${MEETINGTAPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | awk 'index($0,"Developer ID Application:") && index($0,"(9N7UKH59LC)") {split($0,a,"\""); print a[2]; exit}')"
fi
swift build -c "$CONFIGURATION" --product MeetingTapeDesktop
BUILD_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/.build/local/$CONFIGURATION/MeetingTape.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/Resources/Desktop-Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIRECTORY/MeetingTapeDesktop" "$APP/Contents/MacOS/MeetingTape.next"
mv -f "$APP/Contents/MacOS/MeetingTape.next" "$APP/Contents/MacOS/MeetingTape"
cp "$ROOT/.build/local/$CONFIGURATION/meetingtape" "$APP/Contents/Helpers/meetingtape.next"
mv -f "$APP/Contents/Helpers/meetingtape.next" "$APP/Contents/Helpers/meetingtape"
mkdir -p "$APP/Contents/Resources/Transcription"
cp -R "$ROOT/Resources/Transcription/." "$APP/Contents/Resources/Transcription/"
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp -R "$ROOT/Resources/ThirdParty/." "$APP/Contents/Resources/ThirdParty/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
TIMESTAMP="--timestamp=none"
if [[ "$CONFIGURATION" == release ]]; then TIMESTAMP="--timestamp"; fi
/usr/bin/codesign --force --options runtime "$TIMESTAMP" --entitlements "$ROOT/Resources/meetingtape.entitlements" --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/shasum -a 256 "$APP/Contents/MacOS/MeetingTape" "$APP/Contents/Helpers/meetingtape" > "$ROOT/.build/local/$CONFIGURATION/desktop-sha256.txt"
echo "$APP"
