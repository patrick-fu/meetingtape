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
    let result = invoke([])
    #expect(result.exitCode == ExitCode.ok)
    for command in ["start", "stop", "status", "doctor", "recover"] {
        #expect(result.stdout.contains(command))
    }
    #expect(result.stdout.contains("meetingtape help <command>"))
}

@Test func versionFlag() {
    let result = invoke(["--version"])
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("meetingtape \(meetingTapeVersion)"))
}

@Test func unknownCommandIsUsageError() {
    let result = invoke(["frobnicate"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("unknown command"))
}

@Test func everyCommandExplainsItself() {
    for topic in ["start", "stop", "status", "doctor", "recover"] {
        let viaHelp = invoke(["help", topic])
        #expect(viaHelp.exitCode == ExitCode.ok)
        #expect(!viaHelp.stdout.isEmpty)
        let viaFlag = invoke([topic, "--help"])
        #expect(viaFlag.exitCode == ExitCode.ok)
        #expect(viaFlag.stdout == viaHelp.stdout)
    }
}

@Test func unknownHelpTopicIsUsageError() {
    let result = invoke(["help", "wat"])
    #expect(result.exitCode == ExitCode.usage)
}

@Test func startRequiresOutDirectory() {
    let result = invoke(["start"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("--out"))
}

@Test func startRejectsUnknownOption() {
    let result = invoke(["start", "--wat"])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("unknown option"))
}

@Test func startRejectsMissingDirectory() {
    let missing = NSTemporaryDirectory() + "meetingtape-missing-\(UUID().uuidString)"
    let result = invoke(["start", "--out", missing])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("does not exist"))
}

@Test func startRejectsFileAsOutDirectory() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetingtape-file-\(UUID().uuidString)")
    try Data().write(to: url)
    let result = invoke(["start", "--out", url.path])
    #expect(result.exitCode == ExitCode.usage)
    #expect(result.stderr.contains("not a directory"))
}

@Test func startReportsReadinessFailure() {
    let directory = makeTempDirectory()
    let result = invoke(["start", "--out", directory, "--keep-raw"])
    #expect(result.exitCode == ExitCode.capture)
    #expect(result.stderr.contains("capture readiness failed"))
}

@Test func stopWithoutSessionExits3() {
    let result = invoke(["stop"])
    #expect(result.exitCode == ExitCode.noActiveSession)
    #expect(result.stderr.contains("no active"))
}

@Test func statusWithoutSessionIsNormalAnswer() {
    let result = invoke(["status"])
    #expect(result.exitCode == ExitCode.ok)
    #expect(result.stdout.contains("no active recording session"))
}

private func invoke(_ arguments: [String]) -> RunResult {
    let services = CommandServices(
        start: { _ in throw HostFailure("capture readiness failed") },
        status: { nil }, stop: { nil },
        recover: { _, _ in throw HostFailure("recovery failed") }
    )
    return MeetingTapeCLI.run(arguments, services: services)
}
