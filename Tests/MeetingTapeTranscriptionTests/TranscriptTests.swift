import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test func comparisonMatchesTimeDespiteDifferentSentenceBoundaries() {
    let segment = TranscriptSegment(id: 0, start: 5, end: 9, text: "稍后继续")
    let other = TranscriptResult(model: .moss, revision: "fixture", segments: [
        TranscriptSegment(id: 0, start: 0, end: 2, text: "开始"),
        TranscriptSegment(id: 1, start: 5, end: 7, text: "稍后"),
        TranscriptSegment(id: 2, start: 7, end: 9, text: "继续")])
    #expect(TranscriptComparison.matching(segment, in: other).map(\.id) == [1, 2])
    #expect(!TranscriptComparison.differs("稍后继续。", from: "稍后 继续"))
    #expect(TranscriptComparison.differs("不会继续", from: "会继续"))
}

@Test func cloudTimestampsUseSecondsAndKeepRealSpeakerLabels() throws {
    let response = Doubao.Response(code: "20000000", logID: nil, body: ["result": ["utterances": [
        ["start_time": 1200.0, "end_time": 2600.0, "text": "你好", "additions": ["speaker": "2"]],
        ["start_time": -10.0, "end_time": 500.0, "text": "invalid"]]]])
    let result = try Doubao.parse(response, duration: 2)
    #expect(result.segments.count == 1)
    #expect(result.segments[0].start == 1.2)
    #expect(result.segments[0].end == 2)
    #expect(result.segments[0].speaker == "2")
}

@Test func savingOldPreferencesPreservesNewlyActivatedModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var draft = try store.settings()
    let installation = LocalInstallation(family: "qwen", profile: "low-memory", python: "/python", model: "/model", revision: "fixed", repository: "fixture", runtimeVersion: "fixture", ready: true)
    try store.activate(installation)
    draft.models = [.qwen, .doubao]
    try store.saveSettings(draft)
    let saved = try store.settings()
    #expect(saved.models == [.qwen, .doubao])
    #expect(saved.installations["qwen"] == installation)
}

@Test func legacyCloudTaskKeepsItsMergedRequestAndProgress() throws {
    let data = Data("""
    {"schemaVersion":1,"id":"1d2b32c3-6b8e-4b03-95c2-8e302c8a9be0","inputPath":"/fixture.m4a","inputSHA256":"fixture","duration":20,"createdAt":"2026-10-29T00:00:00Z","primaryModel":"doubao","runs":[{"model":"doubao","revision":"fixture","state":"failed","completedChunks":1,"cloudRequestID":"original-request","cloudSubmission":"submitting"}]}
    """.utf8)
    let task = try JSONDecoder().decode(TranscriptionTask.self, from: data)
    #expect(task.recognitionMode == .merged)
    #expect(task.runs[0].sources.count == 1)
    #expect(task.runs[0].sources[0].source == .merged)
    #expect(task.runs[0].sources[0].cloudRequestID == "original-request")
    #expect(task.runs[0].sources[0].cloudSubmission == "submitting")
    #expect(task.runs[0].sources[0].completedChunks == 1)
    let restored = try JSONDecoder().decode(TranscriptionTask.self, from: JSONEncoder().encode(task))
    #expect(restored.runs[0].sources[0].cloudRequestID == "original-request")
}

@Test func failedSourcePreservesOtherSourceAndPartialText() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-sources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var run = TranscriptRun(model: .qwen, revision: "fixture", sources: [.system, .microphone])
    run.sources[0].state = .succeeded
    run.sources[1].state = .failed
    run.sources[1].completedChunks = 1
    let task = TranscriptionTask(schemaVersion: 2, id: UUID().uuidString.lowercased(), inputPath: "/fixture.m4a", inputSHA256: "fixture", duration: 60, createdAt: "2026-10-29T00:00:00Z", primaryModel: .qwen, runs: [run], recognitionMode: .separate, nativeSourceMapping: true)
    try TranscriptionStore.directory(store.taskDirectory(task.id))
    try store.save(task)
    let system = TranscriptResult(model: .qwen, revision: "fixture", segments: [TranscriptSegment(id: 0, start: 1, end: 4, text: "系统原文", source: .system)])
    let microphone = TranscriptResult(model: .qwen, revision: "fixture", segments: [TranscriptSegment(id: 1, start: 2, end: 5, text: "麦克风部分原文", source: .microphone)])
    let systemPath = try store.resultPath(task.id, model: .qwen, source: .system)
    try store.write(system, to: systemPath)
    let before = try Data(contentsOf: systemPath)
    try store.write(LocalProgress(result: microphone, completedChunks: 1), to: store.resultPath(task.id, model: .qwen, source: .microphone, partial: true))
    let combined = try store.result(task.id, model: .qwen)
    #expect(task.finished && task.state == "partial")
    #expect(combined.partial)
    #expect(combined.segments.map(\.source) == [.system, .microphone])
    #expect(TranscriptComparison.matching(system.segments[0], in: microphone).isEmpty)
    #expect(try Data(contentsOf: systemPath) == before)
}
