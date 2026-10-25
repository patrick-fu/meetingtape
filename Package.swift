// swift-tools-version:6.0
import PackageDescription

let apmLibraries = ["meetingtape_apm", "webrtc-audio-processing-2", "absl_base", "absl_flags",
                    "absl_container", "absl_debugging", "absl_strings", "absl_crc", "absl_numeric",
                    "absl_profiling", "absl_hash", "absl_synchronization", "absl_time", "absl_types"]

let package = Package(
    name: "meetingtape",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MeetingTapeCore", targets: ["MeetingTapeCore"]),
        .executable(name: "meetingtape", targets: ["MeetingTapeCLI"]),
        .executable(name: "MeetingTapeDesktop", targets: ["MeetingTapeDesktop"]),
    ],
    targets: [
        .systemLibrary(name: "APMBridge", path: "Sources/APMBridge"),
        .target(
            name: "CaptureSupport",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .target(
            name: "MeetingTapeCore",
            dependencies: ["CaptureSupport", "APMBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("IOKit"), .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-L", "\(Context.packageDirectory)/.build/apm/lib"] + apmLibraries.map { "-l\($0)" })
            ]
        ),
        .executableTarget(
            name: "MeetingTapeCLI",
            dependencies: ["MeetingTapeCore"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(name: "MeetingTapeDesktop", dependencies: ["MeetingTapeCore"]),
        .testTarget(name: "MeetingTapeCoreTests", dependencies: ["MeetingTapeCore"]),
        .testTarget(
            name: "MeetingTapeCLITests",
            dependencies: ["MeetingTapeCLI", "MeetingTapeCore"]
        ),
    ]
)
