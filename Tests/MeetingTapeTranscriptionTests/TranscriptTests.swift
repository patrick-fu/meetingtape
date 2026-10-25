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
