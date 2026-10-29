import Foundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeTranscription

@Test func liveReaderSelectsStereoSourcesAcrossCommittedGapsAndFinalTail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-audio-sources-\(UUID().uuidString)")
    let recovery = root.appendingPathComponent("recovery")
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var snapshot = SessionSnapshot(recoveryPath: recovery.path)
    snapshot.state = .recording
    let writer = try RecoveryStore(directory: recovery, keepRaw: false, snapshot: snapshot)
    try writer.append(stereo: Array(repeating: [Float(0.2), Float(-0.1)], count: 480).flatMap { $0 }, rawMicrophone: nil, at: 0)
    try writer.append(stereo: Array(repeating: [Float(0.4), Float(0.2)], count: 480).flatMap { $0 }, rawMicrophone: nil, at: 960)
    snapshot.elapsedSeconds = 0.03
    try writer.checkpoint(snapshot)

    let sources: [(TranscriptSource, Float, Float, Float)] = [
        (.system, 0.2, 0.4, 0.6),
        (.microphone, -0.1, 0.2, -0.4),
        (.merged, 0.05, 0.3, 0.1),
    ]
    let readers = sources.map { LiveAudioReader(snapshot: snapshot, startFrame: 0, source: $0.0) }
    for (reader, (_, first, second, _)) in zip(readers, sources) {
        let samples = try #require(try reader.readCommitted())
        #expect(samples.count == 1440)
        #expect(abs(samples[100] - first) < 0.00001)
        #expect(samples[700] == 0)
        #expect(abs(samples[1200] - second) < 0.00001)
    }

    try writer.append(stereo: Array(repeating: [Float(0.6), Float(-0.4)], count: 480).flatMap { $0 }, rawMicrophone: nil, at: 1440)
    snapshot.elapsedSeconds = 0.04
    let completed = try writer.finalize(snapshot, outputDirectory: root)
    for (reader, (_, _, _, expected)) in zip(readers, sources) {
        let tail = try #require(try reader.readFinal(completed))
        #expect(tail.count == 480)
        let middle = tail.dropFirst(80).prefix(320)
        let mean = middle.reduce(0, +) / Float(middle.count)
        #expect(abs(mean - expected) < 0.04)
    }
}
