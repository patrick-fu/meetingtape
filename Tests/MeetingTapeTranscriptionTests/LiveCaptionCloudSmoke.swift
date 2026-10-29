import Foundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeTranscription

private actor LiveUpdateLog {
    var partials = 0
    func receive(_ value: LiveCaptionArchive) {
        if value.segments.contains(where: { !$0.final }) { partials += 1 }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_LIVE_SMOKE_ROOT"] != nil), .timeLimit(.minutes(1)))
func liveCloudSyntheticRecordingStreamsRevisionsFinishesAndPersists() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["MEETINGTAPE_LIVE_SMOKE_ROOT"]), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let source = URL(fileURLWithPath: try #require(environment["MEETINGTAPE_LIVE_SYNTHETIC_PCM"]))
    let credential = DoubaoCredential(apiKey: environment["DOUBAO_API_KEY"] ?? "", appID: environment["DOUBAO_APPID"] ?? "", accessToken: environment["DOUBAO_ACCESS_TOKEN"] ?? "")
    guard credential.valid else { throw TranscriptionFailure("缺少豆包测试凭据") }
    let output = root.appendingPathComponent("output", isDirectory: true)
    let recovery = root.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    var snapshot = SessionSnapshot(recoveryPath: recovery.path)
    snapshot.state = .recording
    let writer = try RecoveryStore(directory: recovery, keepRaw: false, snapshot: snapshot)
    let store = LiveCaptionStore(directory: root.appendingPathComponent("library/LiveCaptions"))
    let service = LiveCaptionSession(snapshot: snapshot, store: store, credential: credential)
    let log = LiveUpdateLog()
    let work = Task { await service.run { await log.receive($0) } }
    do {
        let audio = try Data(contentsOf: source)
        let frames = audio.count / 2
        var written: Int64 = 0
        for beginning in stride(from: 0, to: frames, by: 8000) {
            let count = min(8000, frames - beginning)
            var stereo: [Float] = []
            stereo.reserveCapacity(count * 6)
            audio.withUnsafeBytes { bytes in
                for index in beginning..<(beginning + count) {
                    let sample = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                    for _ in 0..<3 { stereo.append(sample); stereo.append(sample) }
                }
            }
            try writer.append(stereo: stereo, rawMicrophone: nil, at: written)
            written += Int64(count * 3)
            snapshot.elapsedSeconds = Double(written) / 48000
            try writer.checkpoint(snapshot)
            try await Task.sleep(for: .milliseconds(500))
        }
        let completed = try writer.finalize(snapshot, outputDirectory: output)
        await service.finish(completed)
        let result = await work.value
        #expect(await log.partials > 0)
        #expect(result.complete, Comment(rawValue: result.message ?? "未完成定稿"))
        let text = result.segments.map(\.text).joined()
        #expect(text.contains("模型"))
        #expect(text.contains("时间"))
        let reopened = try await store.load(snapshot.sessionID)
        #expect(reopened?.segments == result.segments)
        #expect(reopened?.complete == true)
        try JSONEncoder().encode(result).write(to: root.appendingPathComponent("cloud-smoke-result.json"), options: .atomic)
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(completed))
        let index: [[String: Any]] = [["snapshot": metadata, "title": "实时字幕验收 · 合成语音", "starred": false]]
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("library/library.json"), options: .atomic)
    } catch {
        work.cancel(); await service.cancel(); _ = await work.value
        throw error
    }
}
