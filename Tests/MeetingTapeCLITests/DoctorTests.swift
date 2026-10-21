import Foundation
import Testing
import MeetingTapeCore
@testable import MeetingTapeCLI

private func snapshot(
    major: Int = 26,
    minor: Int = 6,
    inputs: Int = 2,
    outputs: Int = 3,
    enumerationFailed: Bool = false
) -> DoctorSnapshot {
    DoctorSnapshot(
        osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 2),
        deviceCounts: enumerationFailed ? nil : (inputs, outputs),
        deviceEnumerationFailed: enumerationFailed
    )
}

@Test func readyEnvironmentPasses() {
    let result = DoctorCommand.report(snapshot: snapshot(), outDirectory: nil)
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("ok: macOS"))
    #expect(result.stdout.contains("environment ready"))
}

@Test func unsupportedMacOSFails() {
    let result = DoctorCommand.report(snapshot: snapshot(major: 13, minor: 0), outDirectory: nil)
    #expect(result.exitCode == ExitCode.environment)
    #expect(result.stdout.contains("too old"))
}

@Test func enumerationFailureFails() {
    let result = DoctorCommand.report(snapshot: snapshot(enumerationFailed: true), outDirectory: nil)
    #expect(result.exitCode == ExitCode.environment)
    #expect(result.stdout.contains("could not be enumerated"))
}

@Test func missingInputDeviceFails() {
    let result = DoctorCommand.report(snapshot: snapshot(inputs: 0), outDirectory: nil)
    #expect(result.exitCode == ExitCode.environment)
}

@Test func missingOutDirectoryFails() {
    let missing = NSTemporaryDirectory() + "meetingtape-doctor-missing-\(UUID().uuidString)"
    let result = DoctorCommand.report(snapshot: snapshot(), outDirectory: missing)
    #expect(result.exitCode == ExitCode.environment)
    #expect(result.stdout.contains("does not exist"))
}

@Test func writableOutDirectoryPasses() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetingtape-doctor-ok-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let result = DoctorCommand.report(snapshot: snapshot(), outDirectory: url.path)
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("writable"))
}
