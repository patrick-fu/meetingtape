// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "meetingtape",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MeetingTapeCore", targets: ["MeetingTapeCore"]),
        .executable(name: "meetingtape", targets: ["MeetingTapeCLI"]),
    ],
    targets: [
        .target(name: "MeetingTapeCore"),
        .executableTarget(
            name: "MeetingTapeCLI",
            dependencies: ["MeetingTapeCore"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(name: "MeetingTapeCoreTests", dependencies: ["MeetingTapeCore"]),
        .testTarget(
            name: "MeetingTapeCLITests",
            dependencies: ["MeetingTapeCLI", "MeetingTapeCore"]
        ),
    ]
)
