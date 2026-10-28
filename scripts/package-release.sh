#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
PROFILE="${MEETINGTAPE_NOTARY_PROFILE:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "Usage: scripts/package-release.sh <version>; optionally set MEETINGTAPE_NOTARY_PROFILE" >&2
    exit 1
fi
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "A validated Resources/AppIcon.icns is required before creating a release candidate." >&2
    exit 1
fi
cd "$ROOT"
./scripts/build-desktop.sh release
BUILD="$ROOT/.build/local/release"
if [[ "$("$BUILD/meetingtape" --version)" != "meetingtape $VERSION" ]]; then
    echo "The compiled CLI version does not match $VERSION." >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD/MeetingTape.app/Contents/Info.plist")" != "${VERSION%%-*}" ]]; then
    echo "The App version does not match $VERSION." >&2
    exit 1
fi
OUTPUT="$ROOT/.build/distribution/$VERSION"
STAGE="$OUTPUT/content"
if [[ -e "$OUTPUT" ]]; then
    echo "Release output already exists: $OUTPUT. Keep it for review; choose a new version or move it aside." >&2
    exit 1
fi
mkdir -p "$STAGE/CLI" "$STAGE/ThirdParty"
ditto "$BUILD/MeetingTape.app" "$STAGE/MeetingTape.app"
cp "$BUILD/meetingtape" "$STAGE/CLI/meetingtape"
ditto "$BUILD/Transcription" "$STAGE/CLI/Transcription"
ditto "$ROOT/Resources/ThirdParty" "$STAGE/ThirdParty"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/CHANGELOG.md" "$STAGE/CHANGELOG.md"
cp "$ROOT/docs/distribution.md" "$STAGE/使用说明.md"
ln -s /Applications "$STAGE/Applications"
cmp "$STAGE/CLI/meetingtape" "$STAGE/MeetingTape.app/Contents/Helpers/meetingtape"
diff -qr "$STAGE/CLI/Transcription" "$STAGE/MeetingTape.app/Contents/Resources/Transcription"
IDENTITY="${MEETINGTAPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | awk 'index($0,"Developer ID Application:") && index($0,"(9N7UKH59LC)") {split($0,a,"\""); print a[2]; exit}')"
fi
DMG="$OUTPUT/MeetingTape-$VERSION-arm64-UNNOTARIZED.dmg"
hdiutil create -volname "MeetingTape $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
if [[ -z "$PROFILE" ]]; then
    (cd "$OUTPUT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS-UNNOTARIZED.txt)
    echo "Signed candidate only; not notarized: $DMG"
    exit 0
fi
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --timeout 15m --output-format json > "$OUTPUT/notary-result.json"
python3 - "$OUTPUT/notary-result.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "Accepted":
    raise SystemExit("Notarization was not Accepted; keep this candidate and inspect the submission log.")
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
FINAL="$OUTPUT/MeetingTape-$VERSION-arm64.dmg"
mv "$DMG" "$FINAL"
(cd "$OUTPUT" && shasum -a 256 "$(basename "$FINAL")" > SHA256SUMS.txt)
echo "Notarized and stapled container: $FINAL"
echo "Download and first-launch acceptance is still required before publishing."
