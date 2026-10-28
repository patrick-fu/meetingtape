import Foundation
import Testing
@testable import MeetingTapeTranscription

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
