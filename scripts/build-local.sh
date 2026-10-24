#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: scripts/build-local.sh [debug|release]" >&2; exit 1 ;;
esac
cd "$ROOT"
./scripts/build-apm.sh
IDENTITY="${MEETINGTAPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | awk 'index($0,"Developer ID Application:") && index($0,"(9N7UKH59LC)") {split($0,a,"\""); print a[2]; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "A valid Developer ID Application identity for Team 9N7UKH59LC is required." >&2
    exit 1
fi
BUILD_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"
rm -f "$BUILD_DIRECTORY/meetingtape"
swift build -c "$CONFIGURATION" --product meetingtape \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Resources/Info.plist"
DESTINATION="$ROOT/.build/local/$CONFIGURATION"
mkdir -p "$DESTINATION"
cp "$BUILD_DIRECTORY/meetingtape" "$DESTINATION/meetingtape"
/usr/bin/codesign --force --options runtime --timestamp=none --entitlements "$ROOT/Resources/meetingtape.entitlements" \
    --identifier com.paaatrickfu.meetingtape --sign "$IDENTITY" "$DESTINATION/meetingtape"
/usr/bin/codesign --verify --strict --verbose=2 "$DESTINATION/meetingtape"
/usr/bin/codesign -d --verbose=4 "$DESTINATION/meetingtape" > "$DESTINATION/signature.txt" 2>&1
/usr/bin/codesign -d -r- "$DESTINATION/meetingtape" >> "$DESTINATION/signature.txt" 2>&1
/usr/bin/otool -L "$DESTINATION/meetingtape" > "$DESTINATION/dependencies.txt"
/usr/bin/otool -s __TEXT __info_plist "$DESTINATION/meetingtape" > "$DESTINATION/embedded-info.txt"
/usr/bin/vtool -show-build "$DESTINATION/meetingtape" > "$DESTINATION/build-version.txt"
/usr/bin/shasum -a 256 "$DESTINATION/meetingtape" > "$DESTINATION/sha256.txt"
if ! /usr/bin/grep -q '^TeamIdentifier=9N7UKH59LC$' "$DESTINATION/signature.txt"; then
    echo "The signed binary has an unexpected signing team." >&2
    exit 1
fi
if ! /usr/bin/grep -q '^Identifier=com.paaatrickfu.meetingtape$' "$DESTINATION/signature.txt"; then
    echo "The signed binary has an unexpected identifier." >&2
    exit 1
fi
python3 - "$DESTINATION/meetingtape" <<'PY'
import pathlib
import plistlib
import struct
import subprocess
import sys

binary = pathlib.Path(sys.argv[1])
data = binary.read_bytes()
if struct.unpack_from('<I', data)[0] != 0xfeedfacf:
    raise SystemExit('Expected a thin 64-bit Mach-O binary')
commands = struct.unpack_from('<I', data, 16)[0]
offset = 32
embedded = None
for _ in range(commands):
    command, length = struct.unpack_from('<II', data, offset)
    if command == 0x19:
        sections = struct.unpack_from('<I', data, offset + 64)[0]
        for index in range(sections):
            section = offset + 72 + 80 * index
            if data[section:section + 16].rstrip(b'\0') == b'__info_plist':
                size = struct.unpack_from('<Q', data, section + 40)[0]
                position = struct.unpack_from('<I', data, section + 48)[0]
                embedded = plistlib.loads(data[position:position + size])
    offset += length
if not embedded or embedded.get('CFBundleIdentifier') != 'com.paaatrickfu.meetingtape':
    raise SystemExit('Missing or invalid embedded bundle identifier')
if not all(embedded.get(key) for key in ['NSMicrophoneUsageDescription', 'NSAudioCaptureUsageDescription']):
    raise SystemExit('Missing embedded audio permission descriptions')
dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True)
for line in dependencies.splitlines()[1:]:
    path = line.strip().split(' ', 1)[0]
    if not path.startswith(('/usr/lib/', '/System/Library/')):
        raise SystemExit('Unexpected dynamic dependency: ' + path)
version = subprocess.check_output(['/usr/bin/vtool', '-show-build', str(binary)], text=True)
if 'minos 14.2' not in version:
    raise SystemExit('Unexpected minimum macOS version')
print('Verified embedded permissions, system dependencies and macOS 14.2 deployment target')
PY
echo "$DESTINATION/meetingtape"
