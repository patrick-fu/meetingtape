import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test(arguments: ["missing", "damaged", "partial"])
func exportPreservesReadableSourceAndReportsMissingSuccessfulSource(artifact: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-missing-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var run = TranscriptRun(model: .doubao, revision: "fixture", sources: [.system, .microphone])
    run.sources[0].state = .succeeded; run.sources[1].state = .succeeded
    let task = TranscriptionTask(schemaVersion: 2, id: UUID().uuidString.lowercased(), inputPath: "/fixture.m4a", inputSHA256: "fixture", duration: 12, createdAt: "2026-10-30T00:00:00Z", primaryModel: .doubao, runs: [run], recognitionMode: .separate, nativeSourceMapping: true)
    try TranscriptionStore.directory(store.taskDirectory(task.id))
    try store.save(task)
    let result = TranscriptResult(model: .doubao, revision: "fixture", segments: [TranscriptSegment(id: 0, start: 1, end: 4, text: "可读取的系统原文", source: .system)])
    try store.write(result, to: store.resultPath(task.id, model: .doubao, source: .system))
    if artifact != "missing" {
        try Data("{".utf8).write(to: store.resultPath(task.id, model: .doubao, source: .microphone))
    }
    if artifact == "partial" {
        let partial = TranscriptResult(model: .doubao, revision: "fixture", segments: [TranscriptSegment(id: 1, start: 2, end: 5, text: "可恢复的部分麦克风原文", source: .microphone)])
        try store.write(LocalProgress(result: partial, completedChunks: 1), to: store.resultPath(task.id, model: .doubao, source: .microphone, partial: true))
    }
    let before = try Data(contentsOf: store.taskDirectory(task.id).appendingPathComponent("task.json"))
    let loaded = try store.result(task.id, model: .doubao)
    let snapshot = try TranscriptExportSnapshot.load(task.id, store: store, captions: LiveCaptionStore(directory: root.appendingPathComponent("captions")))
    let markdown = try snapshot.markdown(primary: task.id + ":doubao")
    #expect(loaded.partial)
    #expect(markdown.contains("可读取的系统原文"))
    #expect(markdown.contains("麦克风：成功，正文缺失或不可读取"))
    #expect(markdown.contains("状态：部分正文"))
    #expect(markdown.contains("可恢复的部分麦克风原文") == (artifact == "partial"))
    #expect(try Data(contentsOf: store.taskDirectory(task.id).appendingPathComponent("task.json")) == before)
    if artifact != "missing" { #expect(try Data(contentsOf: store.resultPath(task.id, model: .doubao, source: .microphone)) == Data("{".utf8)) }
}

@Test func unreadableOldVersionDoesNotBlockAnIndependentPrimary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-unreadable-version-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(root: root)
    var old = TranscriptRun(model: .doubao, revision: "fixture")
    var readable = TranscriptRun(model: .moss, revision: "fixture")
    old.sources[0].state = .succeeded; readable.sources[0].state = .succeeded
    var task = TranscriptionTask(id: UUID().uuidString.lowercased(), inputPath: "/fixture.m4a", inputSHA256: "fixture", duration: 12, createdAt: "2026-10-30T00:00:00Z", primaryModel: .moss, runs: [old, readable])
    try TranscriptionStore.directory(store.taskDirectory(task.id)); try store.save(task)
    try store.write(TranscriptResult(model: .moss, revision: "fixture", segments: [TranscriptSegment(id: 0, start: 1, end: 4, text: "独立完好的主稿")]), to: store.resultPath(task.id, model: .moss, source: .merged))
    let snapshot = try TranscriptExportSnapshot.load(task.id, store: store, captions: LiveCaptionStore(directory: root.appendingPathComponent("captions")))
    let single = try snapshot.markdown(primary: task.id + ":moss")
    #expect(single.contains("独立完好的主稿") && !single.contains("正文缺失或不可读取"))
    let all = try snapshot.markdown(primary: task.id + ":moss", includeVersions: true)
    #expect(all.contains("独立完好的主稿") && all.contains("正文缺失或不可读取"))
    #expect(throws: TranscriptionFailure.self) { try snapshot.markdown(primary: task.id + ":doubao") }
    task.runs[0].sources[0].state = .failed
    try store.save(task)
    let failed = try TranscriptExportSnapshot.load(task.id, store: store, captions: LiveCaptionStore(directory: root.appendingPathComponent("captions")))
    let failureRecord = try failed.markdown(primary: task.id + ":doubao")
    #expect(failureRecord.contains("状态：失败") && failureRecord.contains("执行记录已保留"))
    let captionDirectory = root.appendingPathComponent("captions")
    try TranscriptionStore.directory(captionDirectory)
    let damagedArchive = captionDirectory.appendingPathComponent(task.id + ".json")
    try Data("{".utf8).write(to: damagedArchive)
    let withDamagedLive = try TranscriptExportSnapshot.load(task.id, store: store, captions: LiveCaptionStore(directory: captionDirectory))
    #expect(try withDamagedLive.markdown(primary: task.id + ":moss").contains("独立完好的主稿"))
    #expect(try withDamagedLive.markdown(primary: task.id + ":moss", includeVersions: true).contains("实时归档不可读取"))
    #expect(throws: TranscriptionFailure.self) { try withDamagedLive.markdown(primary: "live") }
    #expect(try Data(contentsOf: damagedArchive) == Data("{".utf8))
}

@Test func markdownKeepsVersionsSourcesAndEscapesModelText() throws {
    var run = TranscriptRun(model: .qwen, revision: "fixture", sources: [.system, .microphone])
    run.sources[0].state = .succeeded; run.sources[1].state = .failed
    let task = TranscriptionTask(schemaVersion: 2, id: UUID().uuidString.lowercased(), inputPath: "/private/recording.m4a", inputSHA256: "private-hash", duration: 12, createdAt: "2026-10-29T00:00:00Z", primaryModel: .qwen, runs: [run], recognitionMode: .separate, nativeSourceMapping: true)
    let result = TranscriptResult(model: .qwen, revision: "fixture", segments: [TranscriptSegment(id: 0, start: 1, end: 4, text: "第一行\n</details><script>alert(1)</script>\n# 伪造标题", precision: "chunk", source: .system)], partial: true)
    var live = LiveCaptionArchive(sessionID: task.id)
    live.segments = [LiveCaptionSegment(id: "fixture", start: 2.123, end: 4.567, text: "独立实时稿", final: false)]
    let primary = TranscriptExportVersion(task: task, run: run, result: result)
    let snapshot = TranscriptExportSnapshot(title: "合成夹具", versions: [primary, TranscriptExportVersion(live: live)], duration: 12)
    let single = try snapshot.markdown(primary: primary.id)
    let all = try snapshot.markdown(primary: primary.id, includeVersions: true)
    #expect(!single.contains("独立实时稿"))
    #expect(all.contains("独立实时稿") && all.contains("未定稿"))
    #expect(all.contains("麦克风：失败"))
    #expect(all.contains("[00:00:01–00:00:04] 系统音频 · 音频块时间"))
    #expect(all.contains("00:00:02.123–00:00:04.567"))
    #expect(all.contains("&lt;/details&gt;&lt;script&gt;"))
    #expect(!all.contains("<script>") && !all.contains(task.inputPath) && !all.contains(task.inputSHA256))
    #expect(all.components(separatedBy: "<details>").count == all.components(separatedBy: "</details>").count)
    #expect(all.contains("未采集"))
}
