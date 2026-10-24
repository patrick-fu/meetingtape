#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}"
STABLE="$TMP/meetingtape-apm-v2.1"
SRC="$STABLE/webrtc-audio-processing-2.1"
BUILD="$STABLE/build"
TOOLS="$STABLE/venv"
OUT="$ROOT/.build/apm"
LIB="$OUT/lib"

APM_URL="https://gstreamer.freedesktop.org/data/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz"
APM_SHA="ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
ABSEIL_SHA="f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3"
ABSEIL_PATCH_SHA="12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b"
ABSEIL_URL="https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz"
ABSEIL_PATCH_URL="https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch"

export MACOSX_DEPLOYMENT_TARGET=14.2
export PATH="$TOOLS/bin:${PATH:-/usr/bin:/bin}"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "$STABLE"
if [[ ! -x "$TOOLS/bin/meson" ]] || [[ "$("$TOOLS/bin/meson" --version 2>/dev/null || true)" != "1.11.2" ]] || [[ "$("$TOOLS/bin/ninja" --version 2>/dev/null || true)" != 1.13.2* ]]; then
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --disable-pip-version-check meson==1.11.2 ninja==1.13.2
fi

tarball="$STABLE/webrtc-audio-processing-2.1.tar.xz"
if [[ ! -f "$tarball" ]] || [[ "$(sha256_file "$tarball")" != "$APM_SHA" ]]; then
  curl -fL --retry 3 -o "$tarball.partial" "$APM_URL"
  mv "$tarball.partial" "$tarball"
fi
if [[ "$(sha256_file "$tarball")" != "$APM_SHA" ]]; then
  echo "webrtc-audio-processing tarball hash mismatch" >&2
  exit 1
fi

if [[ ! -f "$SRC/meson.build" ]]; then
  rm -rf "$SRC"
  tar -xf "$tarball" -C "$STABLE"
fi

stamp="$STABLE/build.stamp"
expected_stamp="static release forcefallback c++17 ${APM_SHA} ${ABSEIL_SHA}"
if [[ ! -f "$BUILD/build.ninja" ]] || [[ ! -f "$stamp" ]] || [[ "$(cat "$stamp")" != "$expected_stamp" ]]; then
  rm -rf "$BUILD"
  meson setup "$BUILD" "$SRC" \
    --default-library=static \
    --buildtype=release \
    --wrap-mode=forcefallback \
    -Dcpp_std=c++17
  printf '%s\n' "$expected_stamp" > "$stamp"
fi

abseil_tar="$(find "$SRC/subprojects/packagecache" -name 'abseil-cpp-20240722.0.tar.gz' -print -quit)"
abseil_patch="$(find "$SRC/subprojects/packagecache" -name 'abseil-cpp_20240722.0-3*' -print -quit)"
if [[ -z "$abseil_tar" ]] || [[ "$(sha256_file "$abseil_tar")" != "$ABSEIL_SHA" ]]; then
  echo "pinned Abseil tarball missing or hash mismatch" >&2
  exit 1
fi
if [[ -z "$abseil_patch" ]] || [[ "$(sha256_file "$abseil_patch")" != "$ABSEIL_PATCH_SHA" ]]; then
  echo "pinned Abseil wrap patch missing or hash mismatch" >&2
  exit 1
fi

ninja -C "$BUILD" -j 4 \
  webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a \
  subprojects/abseil-cpp-20240722.0/libabsl_base.a \
  subprojects/abseil-cpp-20240722.0/libabsl_flags.a \
  subprojects/abseil-cpp-20240722.0/libabsl_container.a \
  subprojects/abseil-cpp-20240722.0/libabsl_debugging.a \
  subprojects/abseil-cpp-20240722.0/libabsl_strings.a \
  subprojects/abseil-cpp-20240722.0/libabsl_crc.a \
  subprojects/abseil-cpp-20240722.0/libabsl_numeric.a \
  subprojects/abseil-cpp-20240722.0/libabsl_profiling.a \
  subprojects/abseil-cpp-20240722.0/libabsl_hash.a \
  subprojects/abseil-cpp-20240722.0/libabsl_synchronization.a \
  subprojects/abseil-cpp-20240722.0/libabsl_time.a \
  subprojects/abseil-cpp-20240722.0/libabsl_types.a

bridge_object="$BUILD/meetingtape_apm.o"
clang++ -c \
  -std=c++17 \
  -O3 \
  -mmacosx-version-min=14.2 \
  -I "$ROOT/Sources/APMBridge" \
  -I "$BUILD" \
  -I "$SRC" \
  -I "$BUILD/webrtc" \
  -I "$SRC/webrtc" \
  -I "$BUILD/subprojects/abseil-cpp-20240722.0" \
  -I "$SRC/subprojects/abseil-cpp-20240722.0" \
  -o "$bridge_object" \
  "$ROOT/Sources/APMBridge/apm_bridge.cpp"
libtool -static -o "$BUILD/libmeetingtape_apm.a" "$bridge_object"

rm -rf "$LIB"
mkdir -p "$LIB"
cp "$BUILD/libmeetingtape_apm.a" "$LIB/"
cp "$BUILD/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a" "$LIB/"
cp "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_base.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_flags.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_container.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_debugging.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_strings.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_crc.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_numeric.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_profiling.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_hash.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_synchronization.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_time.a \
  "$BUILD/subprojects/abseil-cpp-20240722.0"/libabsl_types.a \
  "$LIB/"

attrib="$ROOT/ThirdParty/APM"
mkdir -p "$attrib/webrtc-audio-processing-2.1" "$attrib/abseil-cpp-20240722.0"
cp "$SRC/COPYING" "$attrib/webrtc-audio-processing-2.1/COPYING"
cp "$SRC/webrtc/LICENSE" "$attrib/webrtc-audio-processing-2.1/LICENSE"
cp "$SRC/webrtc/PATENTS" "$attrib/webrtc-audio-processing-2.1/PATENTS"
cp "$SRC/subprojects/abseil-cpp-20240722.0/LICENSE" "$attrib/abseil-cpp-20240722.0/LICENSE"
if [[ -f "$SRC/subprojects/abseil-cpp-20240722.0/NOTICE" ]]; then
  cp "$SRC/subprojects/abseil-cpp-20240722.0/NOTICE" "$attrib/abseil-cpp-20240722.0/NOTICE"
fi
cat > "$attrib/SOURCES.md" <<EOF
# Pinned APM sources

- webrtc-audio-processing 2.1
  - URL: $APM_URL
  - SHA-256: $APM_SHA
- abseil-cpp 20240722.0
  - URL: $ABSEIL_URL
  - SHA-256: $ABSEIL_SHA
- Abseil Meson wrap patch abseil-cpp_20240722.0-3
  - URL: $ABSEIL_PATCH_URL
  - SHA-256: $ABSEIL_PATCH_SHA

The build uses Meson 1.11.2, Ninja 1.13.2, \`MACOSX_DEPLOYMENT_TARGET=14.2\`, and \`meson setup --default-library=static --buildtype=release --wrap-mode=forcefallback -Dcpp_std=c++17\`. Static archives stay in \`.build/apm/lib\`. Upstream source stays under \`\$TMPDIR/meetingtape-apm-v2.1\`.
EOF

consumer_src="$STABLE/consumer.swift"
cat > "$consumer_src" <<'EOF'
import APMBridge
import Darwin

@main
enum APMConsumer {
    static func main() {
        do {
            try run()
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let frameCount = Int(MEETINGTAPE_APM_FRAME_COUNT)
        guard frameCount == 480 else {
            throw ConsumerError.bad("frame count \(frameCount)")
        }
        let processor = try SpeechProcessor()
        guard let probe = meetingtape_apm_create() else {
            throw ConsumerError.bad("probe create failed")
        }
        defer { meetingtape_apm_destroy(probe) }
        guard meetingtape_apm_digital_3a_enabled(probe) == 1 else {
            throw ConsumerError.bad("digital 3A config mismatch")
        }

        var seed: UInt32 = 1234567
        func nextSample() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.15
        }
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var microphone = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            left[index] = nextSample()
            right[index] = nextSample()
            microphone[index] = (left[index] + right[index]) * 0.3
        }
        let originalLeft = left
        let originalRight = right
        let originalMicrophone = microphone
        let output = try processor.process(
            microphone: microphone,
            referenceLeft: left,
            referenceRight: right,
            delayMilliseconds: 40
        )
        guard microphone == originalMicrophone, left == originalLeft, right == originalRight else {
            throw ConsumerError.bad("input mutated")
        }
        guard output.count == frameCount, output.allSatisfy(\.isFinite) else {
            throw ConsumerError.bad("output invalid")
        }
        do {
            _ = try processor.process(
                microphone: [Float](repeating: 0, count: frameCount - 1),
                referenceLeft: left,
                referenceRight: right,
                delayMilliseconds: 40
            )
            throw ConsumerError.bad("short block accepted")
        } catch let error as SpeechProcessorError {
            guard case .invalidBlock = error else {
                throw error
            }
        }
        print("PASS rate=48000 block_samples=\(frameCount) frames=\(frameCount) input_preserved=true output_finite=true digital_agc=true")
    }
}

enum ConsumerError: Error, CustomStringConvertible {
    case bad(String)

    var description: String {
        switch self {
        case .bad(let reason):
            return reason
        }
    }
}
EOF

consumer="$OUT/meetingtape-apm-consumer"
swiftc \
  -target arm64-apple-macos14.2 \
  -module-name MeetingTapeAPMConsumer \
  -I "$ROOT/Sources/APMBridge" \
  -L "$LIB" \
  -lmeetingtape_apm \
  -lwebrtc-audio-processing-2 \
  -labsl_base \
  -labsl_flags \
  -labsl_container \
  -labsl_debugging \
  -labsl_strings \
  -labsl_crc \
  -labsl_numeric \
  -labsl_profiling \
  -labsl_hash \
  -labsl_synchronization \
  -labsl_time \
  -labsl_types \
  -framework CoreFoundation \
  -lc++ \
  "$ROOT/Sources/MeetingTapeCore/SpeechProcessor.swift" \
  "$consumer_src" \
  -o "$consumer"

"$consumer" | tee "$OUT/consumer.log"
grep -F "PASS rate=48000 block_samples=480 frames=480 input_preserved=true output_finite=true digital_agc=true" "$OUT/consumer.log" >/dev/null

otool -L "$consumer" | tee "$OUT/otool.txt"
unexpected=0
while read -r path; do
  case "$path" in
    /System/Library/Frameworks/*|/usr/lib/libSystem.B.dylib|/usr/lib/libc++.1.dylib|/usr/lib/libc++abi.1.dylib|/usr/lib/libobjc.A.dylib|/usr/lib/swift/*|@rpath/libswift*.dylib)
      ;;
    "")
      ;;
    *)
      echo "unexpected dynamic dependency: $path" >&2
      unexpected=1
      ;;
  esac
done < <(otool -L "$consumer" | awk 'NR>1 {print $1}')
if [[ "$unexpected" -ne 0 ]]; then
  exit 1
fi

vtool -show-build "$consumer" | tee "$OUT/vtool.txt"
grep -q "minos 14.2" "$OUT/vtool.txt"
echo "APM static build and 480-frame consumer passed"
