import Foundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeTranscription

@Test func liveFramesDecodeAcknowledgementPartialAndFinalWithoutLosingSequenceBytes() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/live-caption-frames.json")
    let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: path))
    let frames = try values.map { try #require(Data(base64Encoded: $0)) }
    let acknowledgement = try DoubaoLiveCodec.decode(frames[0], origin: 12.5)
    #expect(!acknowledgement.hasResult)
    let partial = try DoubaoLiveCodec.decode(frames[1], origin: 12.5)
    #expect(partial.segments.map(\.text) == ["今天。"])
    #expect(abs(partial.segments[0].start - 12.76) < 0.0001)
    #expect(!partial.segments[0].final)
    for frame in frames.suffix(2) {
        let result = try DoubaoLiveCodec.decode(frame, origin: 12.5)
        #expect(result.final)
        #expect(result.segments.count == 1)
        #expect(abs(result.segments[0].start - 12.58) < 0.0001)
        #expect(abs(result.segments[0].end - 21.622) < 0.0001)
        #expect(result.segments[0].text == "今天测试语音转写，我们准备在应用中选择本地模型和豆包模型，并且核对时间戳。")
        #expect(result.segments[0].final)
    }
    #expect(throws: (any Error).self) { try DoubaoLiveCodec.decode(frames[2].dropLast(), origin: 0) }
    #expect(throws: (any Error).self) { try DoubaoLiveCodec.decode(Data([0x11, 0x93, 0x10, 0, 0, 0, 0, 1]), origin: 0) }
}

@Test func liveReaderUsesCommittedSpansPreservesGapsAndReadsTheDeletedRecoveryTail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-reader-\(UUID().uuidString)")
    let recovery = root.appendingPathComponent("recovery")
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = SessionSnapshot(recoveryPath: recovery.path)
    snapshot.state = .recording
    let writer = try RecoveryStore(directory: recovery, keepRaw: false, snapshot: snapshot)
    try writer.append(stereo: Array(repeating: [Float(0.2), Float(-0.1)], count: 480).flatMap { $0 }, rawMicrophone: nil, at: 0)
    try writer.append(stereo: Array(repeating: [Float(0.4), Float(0.2)], count: 480).flatMap { $0 }, rawMicrophone: nil, at: 960)
    snapshot.elapsedSeconds = 0.03; try writer.checkpoint(snapshot)
    let reader = LiveAudioReader(snapshot: snapshot, startFrame: 0)
    let samples = try #require(try reader.readCommitted())
    #expect(samples.count == 1440)
    #expect(abs(samples[100] - 0.05) < 0.00001)
    #expect(samples[700] == 0)
    #expect(abs(samples[1200] - 0.3) < 0.00001)
    try writer.append(stereo: Array(repeating: Float(0.2), count: 960), rawMicrophone: nil, at: 1440)
    #expect(try reader.readCommitted() == nil)
    snapshot.elapsedSeconds = 0.04
    let completed = try writer.finalize(snapshot, outputDirectory: root)
    #expect(try reader.readCommitted() == nil)
    let tail = try #require(try reader.readFinal(completed))
    #expect(tail.count == 480)
    #expect(tail.contains { abs($0) > 0.01 })
    #expect(try reader.readFinal(completed) == nil)
}
