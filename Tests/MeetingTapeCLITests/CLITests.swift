import Foundation
import Testing
import MeetingTapeCore
@testable import MeetingTapeCLI

private func makeTempDirectory() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetingtape-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

@Test func overviewListsAllCommands() {
    let result = MeetingTapeCLI.run([])
    #expect(result.exitCode == ExitCode.ok)
    for command in ["start", "stop", "status", "doctor"] {
        #expect(result.stdout.contains(command))
    }
    #expect(result.stdout.contains("meetingtape help <command>"))
}

@Test func versionFlag() {
    let result = MeetingTapeCLI.run(["--version"])
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("meetingtape \(meetingTapeVersion)"))
}

@Test func unknownCommandIsUsageError() {
    let result = MeetingTapeCLI.run(["frobnicate"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("unknown command"))
}

@Test func everyCommandExplainsItself() {
    for topic in ["start", "stop", "status", "doctor"] {
        let viaHelp = MeetingTapeCLI.run(["help", topic])
        #expect(viaHelp.exitCode == ExitCode.ok)
        #expect(!viaHelp.stdout.isEmpty)
        let viaFlag = MeetingTapeCLI.run([topic, "--help"])
        #expect(viaFlag.exitCode == ExitCode.ok)
        #expect(viaFlag.stdout == viaHelp.stdout)
    }
}

@Test func unknownHelpTopicIsUsageError() {
    let result = MeetingTapeCLI.run(["help", "wat"])
    #expect(result.exitCode == ExitCode.usage)
}

@Test func startRequiresOutDirectory() {
    let result = MeetingTapeCLI.run(["start"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("--out"))
}

@Test func startRejectsUnknownOption() {
    let result = MeetingTapeCLI.run(["start", "--wat"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("unknown option"))
}

@Test func startRejectsMissingDirectory() {
    let missing = NSTemporaryDirectory() + "meetingtape-missing-\(UUID().uuidString)"
    let result = MeetingTapeCLI.run(["start", "--out", missing])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("does not exist"))
}

@Test func startRejectsFileAsOutDirectory() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetingtape-file-\(UUID().uuidString)")
    try Data().write(to: url)
    let result = MeetingTapeCLI.run(["start", "--out", url.path])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("not a directory"))
}

@Test func startValidatesThenReportsCaptureUnavailable() {
    let directory = makeTempDirectory()
    let result = MeetingTapeCLI.run(["start", "--out", directory, "--keep-raw"])
    #expect(result.exitCode == ExitCode.capture)
    #expect(result.stderr.contains("capture is not available"))
}

@Test func stopWithoutSessionExits3() {
    let result = MeetingTapeCLI.run(["stop"])
    #expect(result.exitCode == ExitCode.noActiveSession)
    #expect(result.stderr.contains("no active"))
}

@Test func statusWithoutSessionIsNormalAnswer() {
    let result = MeetingTapeCLI.run(["status"])
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("no active recording session"))
}
