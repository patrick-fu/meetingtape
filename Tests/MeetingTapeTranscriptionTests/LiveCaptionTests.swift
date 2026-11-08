import Foundation
import AVFoundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeTranscription

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_LIVE_SMOKE_AUDIO"] != nil), .timeLimit(.minutes(2))) @MainActor
func localLiveSessionConsumesPacedSeparateAudioAndPersistsItsFinalTail() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["MEETINGTAPE_LIVE_SMOKE_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    #expect(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let pointer = try #require(buffer.floatChannelData?[0])
    let mono = Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-consumer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recovery = root.appendingPathComponent("recovery")
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var snapshot = SessionSnapshot(recoveryPath: recovery.path)
    snapshot.state = .recording; snapshot.recognitionMode = .separate
    let writer = try RecoveryStore(directory: recovery, keepRaw: false, snapshot: snapshot)
    let captions = LiveCaptionStore(directory: root.appendingPathComponent("captions"))
    let session = LiveCaptionSession(snapshot: snapshot, store: captions, recognitionProvider: .senseVoice)
    let consumer = Task { await session.run { _ in } }
    defer { consumer.cancel() }
    let clock = ContinuousClock(), began = ContinuousClock.now
    var offset = 0
    while offset < mono.count {
        let end = min(offset + 3200, mono.count)
        try await clock.sleep(until: began.advanced(by: .seconds(Double(end) / 16000)))
        var stereo: [Float] = []; stereo.reserveCapacity((end - offset) * 6)
        for sample in mono[offset..<end] { for _ in 0..<3 { stereo += [sample, 0] } }
        try writer.append(stereo: stereo, rawMicrophone: nil, at: Int64(offset * 3))
        snapshot.elapsedSeconds = Double(end) / 16000; snapshot.committedSeconds = snapshot.elapsedSeconds
        try writer.checkpoint(snapshot); offset = end
    }
    snapshot.state = .finalizing; try writer.checkpoint(snapshot)
    let archive = await consumer.value
    #expect(archive.complete)
    let system = archive.segments.filter { $0.source == .system }.map(\.text).joined(separator: " ").uppercased()
    #expect(system.contains("MERGE") && system.contains("BLUE NOTEBOOK") && system.contains("银色灯笼"))
    #expect(archive.segments.filter { $0.source == .microphone }.isEmpty)
    #expect(archive.segments.allSatisfy { $0.final })
    #expect(archive.connections.count == 2 && archive.connections.allSatisfy { $0.complete && $0.provider == .senseVoice && ($0.cpuSeconds ?? 0) > 0 && ($0.peakResidentBytes ?? 0) > 0 })
    #expect(archive.connections.allSatisfy { abs($0.end - snapshot.elapsedSeconds) < 0.001 })
    #expect(try await captions.load(snapshot.sessionID) == archive)
    if let destination = environment["MEETINGTAPE_LIVE_SMOKE_OUTPUT"] { try JSONEncoder().encode(archive).write(to: URL(fileURLWithPath: destination), options: .atomic) }
}

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

@Test func unreadableCaptionArchiveIsPreservedWhenReconnecting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-caption-preservation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionSnapshot(recoveryPath: root.appendingPathComponent("recovery").path)
    let path = root.appendingPathComponent(snapshot.sessionID + ".json")
    let original = Data("{\"schemaVersion\":99,\"originalText\":\"保留已有字幕\"}".utf8)
    try original.write(to: path)
    let service = LiveCaptionSession(snapshot: snapshot, store: LiveCaptionStore(directory: root), credential: DoubaoCredential(apiKey: "unused"))
    let result = await service.run { _ in }
    #expect(!result.complete)
    #expect(result.message != nil)
    #expect(try Data(contentsOf: path) == original)
}

@Test func combinedSourceLimitPreservesLastReadableArchive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-caption-limit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var archive = LiveCaptionArchive(sessionID: UUID().uuidString.lowercased())
    archive.segments = [LiveCaptionSegment(id: "saved", start: 0, end: 1, text: "已有原稿", final: true)]
    try await store.save(archive)
    let path = root.appendingPathComponent(archive.sessionID + ".json"), before = try Data(contentsOf: root.appendingPathComponent(archive.sessionID + ".json"))
    archive.segments = (0...20_000).map { LiveCaptionSegment(id: String($0), start: 0, end: 1, text: "双路合计超限", final: true) }
    await #expect(throws: (any Error).self) { try await store.save(archive) }
    #expect(try Data(contentsOf: path) == before)
    #expect(try await store.load(archive.sessionID)?.segments.first?.text == "已有原稿")
}
