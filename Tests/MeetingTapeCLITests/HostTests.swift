import Darwin
import Foundation
import MeetingTapeCore
import Testing
@testable import MeetingTapeCLI

private final class TestSession: HostSession, @unchecked Sendable {
    var value = SessionSnapshot(recoveryPath: "/preserved/session.recovery")
    var failStart = false
    var failStop = false
    var failDuringRecording = false
    var stopDelay = 0.0

    func start(_ configuration: RecordingConfiguration) throws -> SessionSnapshot {
        if failStart { throw HostFailure("injected readiness failure") }
        value.state = .recording
        value.systemAvailable = true
        value.microphoneAvailable = true
        return value
    }

    func snapshot() -> SessionSnapshot {
        var result = value
        if failDuringRecording && result.state == .recording {
            result.state = .failed
            result.failureReason = "injected capture failure"
        }
        return result
    }

    func stop() throws -> SessionSnapshot {
        Thread.sleep(forTimeInterval: stopDelay)
        if failStop {
            value.state = .failed
            value.failureReason = "injected finalization failure"
            throw HostFailure(value.failureReason!)
        }
        value.state = .completed
        value.outputPath = "/completed/session.m4a"
        return value
    }
}

private func isolatedPaths() throws -> HostPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-host-tests-\(UUID().uuidString)")
    return try HostPaths(environment: ["MEETINGTAPE_STATE_DIR": root.path])
}

@Test func socketRoutesStatusAndWaitsForFinalization() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let session = TestSession()
    session.stopDelay = 0.1
    let host = try RecordingHost(paths: paths, session: session)
    let initial = try host.start(RecordingConfiguration(outputDirectory: NSTemporaryDirectory()))
    #expect(initial.state == .recording)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { host.serve(); done.signal() }
    let status = try #require(try HostTransport.request(.status, paths: paths))
    #expect(status.snapshot?.sessionID == initial.sessionID)
    #expect(status.snapshot?.state == .recording)
    let stop = try #require(try HostTransport.request(.stop, paths: paths))
    #expect(stop.error == nil)
    #expect(stop.snapshot?.state == .completed)
    #expect(stop.snapshot?.outputPath == "/completed/session.m4a")
    #expect(done.wait(timeout: .now() + 2) == .success)
}

@Test func sessionFencedStopRefusesAReplacementSession() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let host = try RecordingHost(paths: paths, session: TestSession())
    let current = try host.start(RecordingConfiguration(outputDirectory: NSTemporaryDirectory()))
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { host.serve(); done.signal() }
    let refused = try #require(try HostTransport.request(.stopSession("previous-session"), paths: paths))
    #expect(refused.error?.contains("session changed") == true)
    let running = try #require(try HostTransport.request(.status, paths: paths))
    #expect(running.snapshot?.sessionID == current.sessionID)
    #expect(running.snapshot?.state == .recording)
    let completed = try #require(try HostTransport.request(.stopSession(current.sessionID), paths: paths))
    #expect(completed.snapshot?.state == .completed)
    #expect(done.wait(timeout: .now() + 2) == .success)
}

@Test func liveHostRetainsExclusiveSessionLock() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let host = try RecordingHost(paths: paths, session: TestSession())
    #expect(throws: HostFailure.self) { try RecordingHost(paths: paths, session: TestSession()) }
    withExtendedLifetime(host) {}
}

@Test func readinessFailureCannotPublishRecording() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let session = TestSession()
    session.failStart = true
    let host = try RecordingHost(paths: paths, session: session)
    #expect(throws: HostFailure.self) { try host.start(RecordingConfiguration(outputDirectory: NSTemporaryDirectory())) }
}

@Test func failedStopPreservesFailureAndRecoveryPath() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let session = TestSession()
    session.failStop = true
    let host = try RecordingHost(paths: paths, session: session)
    _ = try host.start(RecordingConfiguration(outputDirectory: NSTemporaryDirectory()))
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { host.serve(); done.signal() }
    let response = try #require(try HostTransport.request(.stop, paths: paths))
    #expect(response.error == "injected finalization failure")
    #expect(response.snapshot?.recoveryPath == "/preserved/session.recovery")
    #expect(done.wait(timeout: .now() + 2) == .success)
}

@Test func statusJSONUsesAuthoritativeSnapshot() throws {
    var snapshot = SessionSnapshot(sessionID: "actual-session", recoveryPath: "/recovery")
    snapshot.state = .interrupted
    snapshot.degradedIntervals = [RecordingInterval(startSeconds: 1, endSeconds: 2, source: .microphone, reason: "raw fallback")]
    let result = StatusCommand.run(["--json"], status: { snapshot })
    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(result.stdout.utf8))
    #expect(decoded.sessionID == "actual-session")
    #expect(decoded.state == .interrupted)
    #expect(decoded.degradedIntervals == snapshot.degradedIntervals)
}

@Test func automaticCaptureFailureEndsHostAndRetainsFailure() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let session = TestSession()
    session.failDuringRecording = true
    session.failStop = true
    let host = try RecordingHost(paths: paths, session: session)
    _ = try host.start(RecordingConfiguration(outputDirectory: NSTemporaryDirectory()))
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { host.serve(); done.signal() }
    #expect(done.wait(timeout: .now() + 2) == .success)
    let data = try Data(contentsOf: paths.directory.appendingPathComponent("last-session.json"))
    let retained = try JSONDecoder().decode(SessionSnapshot.self, from: data)
    #expect(retained.state == .failed)
    #expect(retained.failureReason == "injected finalization failure")
    #expect(retained.recoveryPath == "/preserved/session.recovery")
}

@Test func recoveredSessionCannotReturnToFailedButNewSessionCanReplaceIt() throws {
    let paths = try isolatedPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    var completed = SessionSnapshot(sessionID: "recovered", recoveryPath: "/recovery")
    completed.state = .completed
    completed.outputPath = "/saved.m4a"
    try SessionCache.store(completed, paths: paths)
    var late = completed
    late.state = .failed
    try SessionCache.store(late, paths: paths)
    let file = paths.directory.appendingPathComponent("last-session.json")
    let retained = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: file))
    #expect(retained.state == .completed)
    #expect(retained.outputPath == "/saved.m4a")
    late.sessionID = "new-session"
    try SessionCache.store(late, paths: paths)
    let replacement = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: file))
    #expect(replacement.sessionID == "new-session")
    #expect(replacement.state == .failed)
}

@Test func recoverRoutesArgumentsAndReportsFinalOutput() {
    let result = RecoverCommand.run(["/recovery", "--out", "/destination"], recover: { source, destination in
        #expect(source == "/recovery")
        #expect(destination == "/destination")
        var snapshot = SessionSnapshot(recoveryPath: source)
        snapshot.state = .completed
        snapshot.outputPath = destination + "/recovered.m4a"
        return snapshot
    })
    #expect(result.exitCode == .ok)
    #expect(result.stdout.contains("/destination/recovered.m4a"))
}

@Test func sessionCommandsRejectUnknownOptions() {
    #expect(StopCommand.run(["--wat"], stop: { nil }).exitCode == .usage)
    #expect(StatusCommand.run(["--wat"], status: { nil }).exitCode == .usage)
    #expect(RecoverCommand.run(["/recovery"], recover: { _, _ in fatalError() }).exitCode == .usage)
}

@Test func mutatingCommandsReturnMachineReadableSnapshotsForDesktop() throws {
    var value = SessionSnapshot(sessionID: "desktop-session", recoveryPath: "/恢复 材料")
    value.state = .recording
    value.systemAvailable = true
    value.microphoneAvailable = true
    let start = StartCommand.run(["--out", NSTemporaryDirectory(), "--json"], start: { _ in value })
    let ready = try JSONDecoder().decode(SessionSnapshot.self, from: Data(start.stdout.utf8))
    #expect(start.exitCode == .ok)
    #expect(ready.sessionID == value.sessionID && ready.state == .recording)
    value.state = .completed
    value.outputPath = "/录音 文件/实际结果.m4a"
    value.degradedIntervals = [RecordingInterval(startSeconds: 1, endSeconds: 2, reason: "raw fallback")]
    let stop = StopCommand.run(["--json"], stop: { value })
    let recover = RecoverCommand.run([value.recoveryPath, "--out", "/录音 文件", "--json"], recover: { _, _ in value })
    for result in [stop, recover] {
        let completed = try JSONDecoder().decode(SessionSnapshot.self, from: Data(result.stdout.utf8))
        #expect(result.exitCode == .ok)
        #expect(completed.state == .completed)
        #expect(completed.outputPath == value.outputPath)
        #expect(completed.degradedIntervals == value.degradedIntervals)
    }
    #expect(StopCommand.run(["--json"], stop: { throw HostFailure("finalization failed") }).exitCode == .capture)
}
