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
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
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
        .target(name: "MeetingTapeTranscription", dependencies: ["MeetingTapeCore"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "MeetingTapeCLI",
            dependencies: ["MeetingTapeCore", "MeetingTapeTranscription"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "MeetingTapeDesktop", dependencies: ["MeetingTapeCore", "MeetingTapeTranscription", "Sparkle"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MeetingTapeCoreTests", dependencies: ["MeetingTapeCore"]),
        .testTarget(
            name: "MeetingTapeCLITests",
            dependencies: ["MeetingTapeCLI", "MeetingTapeCore"]
        ),
        .testTarget(name: "MeetingTapeDesktopTests", dependencies: ["MeetingTapeDesktop"]),
        .testTarget(name: "MeetingTapeTranscriptionTests", dependencies: ["MeetingTapeTranscription"]),
    ]
)
