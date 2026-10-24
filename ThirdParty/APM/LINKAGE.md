# Link MeetingTape to the static APM

`scripts/build-apm.sh` writes the static archives to `.build/apm/lib`. That directory is gitignored. The Swift module `APMBridge` reads `Sources/APMBridge/meetingtape_apm.h`. The script compiles `Sources/APMBridge/apm_bridge.cpp`. Package.swift should declare `APMBridge` as a system library, not as a target that compiles the C++ file.

```swift
.systemLibrary(name: "APMBridge", path: "Sources/APMBridge"),
.target(
    name: "MeetingTapeCore",
    dependencies: ["APMBridge"],
    linkerSettings: [
        .linkedFramework("CoreFoundation"),
        .linkedLibrary("c++"),
        .unsafeFlags([
            "-L", "\(Context.packageDirectory)/.build/apm/lib",
            "-lmeetingtape_apm",
            "-lwebrtc-audio-processing-2",
            "-labsl_base",
            "-labsl_flags",
            "-labsl_container",
            "-labsl_debugging",
            "-labsl_strings",
            "-labsl_crc",
            "-labsl_numeric",
            "-labsl_profiling",
            "-labsl_hash",
            "-labsl_synchronization",
            "-labsl_time",
            "-labsl_types",
        ]),
    ]
),
```

`Context.packageDirectory` is available to this package's tools version. Keep `-lmeetingtape_apm` before `-lwebrtc-audio-processing-2`, and keep that archive before the Abseil archives. If an executable or test link does not inherit these `unsafeFlags`, repeat the same `linkerSettings` on `MeetingTapeCLI`, `MeetingTapeCoreTests`, and `MeetingTapeCLITests`.

Archives:

- `.build/apm/lib/libmeetingtape_apm.a`
- `.build/apm/lib/libwebrtc-audio-processing-2.a`
- `.build/apm/lib/libabsl_base.a`
- `.build/apm/lib/libabsl_flags.a`
- `.build/apm/lib/libabsl_container.a`
- `.build/apm/lib/libabsl_debugging.a`
- `.build/apm/lib/libabsl_strings.a`
- `.build/apm/lib/libabsl_crc.a`
- `.build/apm/lib/libabsl_numeric.a`
- `.build/apm/lib/libabsl_profiling.a`
- `.build/apm/lib/libabsl_hash.a`
- `.build/apm/lib/libabsl_synchronization.a`
- `.build/apm/lib/libabsl_time.a`
- `.build/apm/lib/libabsl_types.a`

Header: `Sources/APMBridge/meetingtape_apm.h`.
