import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test func translationBelongsToRevisionAndTranslationOnlySavesTargetOnce() throws {
    var options = SubtitleOptions(); options.translation = true; options.transcription = false
    var buffer = CaptionDraftBuffer(connectionID: "connection-a", source: .system, options: options)
    let first = buffer.receive([LiveCaptionSegment(id: "server-time", start: 12.76, end: 13, text: "old draft", final: false)])[0]
    let final = buffer.receive([LiveCaptionSegment(id: "changed-server-time", start: 12.58, end: 14, text: "final draft", final: true)])[0]
    #expect(first.id == final.id && first.revision != final.revision)
    let applied1 = buffer.apply(CaptionTranslation(targetLanguage: "zh-Hans", text: "过期译文", state: .translated, provider: "fixture"), id: first.id, revision: first.revision)
    #expect(!applied1)
    let applied2 = buffer.apply(CaptionTranslation(targetLanguage: "zh-Hans", text: "最终译文", state: .translated, provider: "fixture"), id: final.id, revision: final.revision)
    #expect(applied2)
    let bytes = String(decoding: try JSONEncoder().encode(buffer.segments), as: UTF8.self)
    #expect(!bytes.contains("final draft") && !bytes.contains("old draft") && !bytes.contains("过期译文"))
    #expect(buffer.segments[0].targetText == "最终译文")
    let applied3 = buffer.apply(CaptionTranslation(targetLanguage: "en", text: "wrong target", state: .translated, provider: "fixture"), id: final.id, revision: final.revision)
    #expect(!applied3)
    let same = buffer.receive([LiveCaptionSegment(id: "server", start: 12.58, end: 14, text: "已经是中文", final: true)])[0]
    let applied4 = buffer.apply(CaptionTranslation(targetLanguage: "zh-Hans", state: .sameLanguage, provider: "fixture"), id: same.id, revision: same.revision)
    #expect(applied4)
    #expect(buffer.segments[0].text.isEmpty)
    #expect(buffer.segments[0].plainText == "已经是中文")
}

@Test func coverageKeepsBothSourcesSwitchBoundariesAndUnknownObserverGap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-coverage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root), id = UUID().uuidString.lowercased()
    var options = SubtitleOptions(); options.translation = true
    try await store.recordControls(id, at: 0, mode: .separate, options: options)
    options.transcription = false
    try await store.recordControls(id, at: 10, mode: .separate, options: options)
    options.translation = false
    try await store.recordControls(id, at: 20, mode: .separate, options: options)
    options.transcription = true; options.targetLanguage = "en"
    try await store.recordControls(id, at: 30, mode: .separate, options: options)
    options.translation = true
    try await store.recordControls(id, at: 40, mode: .separate, options: options)
    try await store.recordControls(id, at: 50, mode: .separate, options: options)
    try await store.recordControls(id, at: 60, mode: .separate, options: options, newObserver: true)
    var first = CaptionConnection(id: "system", source: .system, start: 0, end: 10, complete: true, state: "completed")
    _ = try await store.updateConnection(id, mode: .separate, connection: first, segments: [LiveCaptionSegment(id: "system", start: 1, end: 2, text: "系统", final: true, source: .system, connectionID: first.id)])
    first.id = "microphone"; first.source = .microphone
    let document = try await store.updateConnection(id, mode: .separate, connection: first, segments: [LiveCaptionSegment(id: "microphone", start: 1, end: 2, text: "麦克风", final: true, source: .microphone, connectionID: first.id)])
    #expect(document.segments.map(\.source).sorted(by: { $0.rawValue < $1.rawValue }) == [.microphone, .system])
    #expect(document.coverage.contains { $0.source == .system && $0.feature == "transcription" && $0.state == "disabled" && $0.start == 10 && $0.end == 30 })
    #expect(document.coverage.contains { $0.source == .microphone && $0.state == "unknown" && $0.start == 50 && $0.end == 60 })
    let markdown = try TranscriptExportSnapshot(title: "覆盖夹具", versions: [TranscriptExportVersion(live: document)]).markdown(primary: "live")
    #expect(markdown.contains("该期间未开启转写") && markdown.contains("该期间未开启字幕翻译"))
    #expect(markdown.contains("历史未记录") && markdown.contains("00:00:10.000–00:00:30.000"))
}

@Test func firstMidRecordingObserverKeepsUnknownPrefix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-mid-caption-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root), id = UUID().uuidString.lowercased()
    var options = SubtitleOptions(); options.translation = true
    try await store.recordControls(id, at: 30, mode: .merged, options: options, newObserver: true)
    try await store.recordControls(id, at: 40, mode: .merged, options: options)
    let connection = CaptionConnection(id: "tail", source: .merged, start: 30, end: 40, complete: true, state: "completed")
    let document = try await store.updateConnection(id, mode: .merged, connection: connection, segments: [LiveCaptionSegment(id: "tail", start: 31, end: 39, text: "尾段", final: true, connectionID: "tail")])
    #expect(!document.complete && document.partial)
    #expect(document.coverage.filter { $0.state == "unknown" && $0.start == 0 && $0.end == 30 }.count == 2)
    let markdown = try TranscriptExportSnapshot(title: "中途接管", versions: [TranscriptExportVersion(live: document)]).markdown(primary: "live")
    #expect(markdown.contains("历史未记录") && markdown.contains("状态：部分字幕"))
}
