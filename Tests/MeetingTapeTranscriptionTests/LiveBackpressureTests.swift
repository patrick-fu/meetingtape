import Foundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeTranscription

private actor EarlyCaptionProbe {
    private(set) var observed = false
    func receive(_ archive: LiveCaptionArchive) {
        if !archive.segments.isEmpty, archive.connections.contains(where: { $0.end < 12 }) { observed = true }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_LIVE_BACKPRESSURE_PROBE"] == "1"), .timeLimit(.minutes(1))) @MainActor
func aSlowLocalRunnerPublishesWhileCommittedAudioRemainsQueued() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-backpressure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = SessionSnapshot(recoveryPath: root.path)
    snapshot.state = .recording; snapshot.recognitionMode = .merged
    let writer = try RecoveryStore(directory: root, keepRaw: false, snapshot: snapshot)
    try writer.append(stereo: [Float](repeating: 0, count: 12 * 48000 * 2), rawMicrophone: nil, at: 0)
    snapshot.elapsedSeconds = 12; snapshot.committedSeconds = 12; snapshot.state = .finalizing
    try writer.checkpoint(snapshot)
    let gate = EarlyCaptionProbe()
    let session = LiveCaptionSession(snapshot: snapshot, store: LiveCaptionStore(directory: root.appendingPathComponent("captions")), recognitionProvider: .senseVoice)
    let consumer = Task { await session.run { await gate.receive($0) } }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, !(await gate.observed) { try await Task.sleep(for: .milliseconds(50)) }
    let observed = await gate.observed
    consumer.cancel(); _ = await consumer.value
    #expect(observed)
}
