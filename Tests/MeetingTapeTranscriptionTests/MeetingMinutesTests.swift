import Foundation
import Testing
@testable import MeetingTapeTranscription

private func minutesFixture(citationID: String = "source", quote: String = "周五交付") -> String {
    """
    {"overview":[{"text":"确定交付时间","citationIDs":["\(citationID)"]}],"topics":[],"decisions":[],"todos":[],"highlights":[{"text":"交付约定","quote":"\(quote)","citationIDs":["\(citationID)"]}],"candidateTerms":[{"canonical":"MeetingTape","aliases":["Meeting 泰普"],"citationIDs":["\(citationID)"]}]}
    """
}

private let minutesSource = TranscriptCitation(id: "source", versionID: "model-version-1", model: "synthetic-asr", source: .microphone, segmentID: "segment-1", revision: "revision-1", start: 12, end: 18, text: "Meeting 泰普，周五交付。")

@Test func minutesRejectUnknownSourcesAndInventedQuotes() async throws {
    for output in [minutesFixture(citationID: "invented"), minutesFixture(quote: "周六交付"), minutesFixture().replacingOccurrences(of: "\"quote\":\"周五交付\",", with: "")] {
        await #expect(throws: (any Error).self) {
            try await MeetingMinutesGenerator.generate(sessionID: UUID().uuidString, citations: [minutesSource], partial: false, provider: "synthetic", model: "fixture", language: "zh") { _, _ in
                MinutesGenerationOutput(content: output)
            }
        }
    }
}

@Test func minutesEditsPreserveFrozenVersionsAndCorruptArchives() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-minutes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingMinutesStore(directory: directory)
    let sessionID = UUID().uuidString.lowercased()
    let original = try await MeetingMinutesGenerator.generate(sessionID: sessionID, citations: [minutesSource], partial: true, provider: "synthetic", model: "fixture", language: "zh") { _, _ in
        MinutesGenerationOutput(content: minutesFixture(), usage: ["output_tokens": 25], elapsedSeconds: 0.01)
    }
    try await store.append(original)
    let edited = try await store.edit(sessionID: sessionID, body: "# 人工编辑\n\n周五交付。", parentID: original.id)
    let versions = try await store.load(sessionID: sessionID)
    #expect(versions == [original, edited])
    #expect(edited.parentID == original.id)
    #expect(edited.citations == original.citations)
    #expect(edited.sourceFingerprint == original.sourceFingerprint)
    #expect(original.body.contains("基于部分记录"))
    #expect(original.markdown().contains("周五交付"))
    #expect(original.markdown().contains("model-version-1"))
    #expect(original.markdown().contains("待确认术语"))
    var ownReference = minutesSource; ownReference.sessionID = sessionID; ownReference.text = "current recording reference"
    var foreignReference = minutesSource; foreignReference.sessionID = UUID().uuidString; foreignReference.text = "foreign recording reference"
    var legacyReference = minutesSource; legacyReference.text = "unknown recording reference"
    let term = ConfirmedTerm(canonical: "MeetingTape", aliases: ["Meeting 泰普"], references: [ownReference, foreignReference, legacyReference])
    let export = try TranscriptExportSnapshot(title: "纪要导出", versions: [TranscriptExportVersion(minutes: original)], confirmedTerms: [term], sessionID: sessionID).markdown(primary: "minutes:" + original.id)
    #expect(export.contains("current recording reference") && export.contains("已确认术语"))
    #expect(!export.contains("foreign recording reference") && !export.contains("unknown recording reference"))
    var revised = minutesSource
    revised.text = "周六交付。"; revised.revision = "revision-2"
    #expect(try original.sourcesChanged([revised]))
    #expect(original.citations[0].text == "Meeting 泰普，周五交付。")
    let path = directory.appendingPathComponent(sessionID + ".json")
    #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let broken = Data("broken archive".utf8)
    try broken.write(to: path)
    await #expect(throws: (any Error).self) { try await store.append(original) }
    #expect(try Data(contentsOf: path) == broken)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_MINUTES_SMOKE_ROOT"] != nil), .timeLimit(.minutes(3)))
func minutesModelProducesCitedDecisionsFromIndependentTranscripts() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["MEETINGTAPE_MINUTES_SMOKE_ROOT"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var draft = TextModelSettings()
    draft.provider = TextModelLocation(rawValue: environment["MEETINGTAPE_MINUTES_SMOKE_PROVIDER"] ?? "local") ?? .local
    let connection = TextModelConnection(baseURL: try #require(environment["MEETINGTAPE_MINUTES_SMOKE_ENDPOINT"]), model: try #require(environment["MEETINGTAPE_MINUTES_SMOKE_MODEL"]))
    if draft.provider == .local { draft.local = connection } else { draft.cloud = connection }
    let settings = draft
    let id = UUID().uuidString.lowercased()
    let sources = [
        TranscriptCitation(id: "qwen-1", sessionID: id, versionID: "qwen-version", model: "Qwen", source: .system, segmentID: "1", revision: "1", start: 0, end: 8, text: "我们决定周五发布 MeetingTape。Alice 在周四完成字幕窗口。项目预算是1000元。"),
        TranscriptCitation(id: "moss-1", sessionID: id, versionID: "moss-version", model: "MOSS", source: .system, segmentID: "1", revision: "1", start: 0, end: 8, text: "决定周五发布 MeetingTape，Alice 周四完成字幕窗口。项目预算是2000元。"),
        TranscriptCitation(id: "live-1", sessionID: id, versionID: "live", model: "live", source: .microphone, segmentID: "1", revision: "1", start: 8, end: 12, text: "Keep the microphone and system audio transcripts separate.")
    ]
    let version = try await MeetingMinutesGenerator.generate(sessionID: id, citations: sources, partial: false, provider: settings.provider.rawValue, model: connection.model, language: "zh-Hans") { system, user in
        let output = try await TextModelClient.generate(system: system, user: user, settings: settings, key: settings.provider == .cloud ? environment["OPENAI_API_KEY"] : nil)
        try Data(output.content.utf8).write(to: root.appendingPathComponent("raw-response.txt"), options: .atomic)
        return output
    }
    #expect(version.body.contains("周五") && version.body.contains("Alice") && version.body.contains("周四"))
    #expect(version.body.contains("待核对") && version.body.contains("1000") && version.body.contains("2000"))
    #expect(version.citations == sources)
    let store = MeetingMinutesStore(directory: root.appendingPathComponent("MeetingMinutes"))
    try await store.append(version)
    try Data(version.markdown().utf8).write(to: root.appendingPathComponent("minutes.md"), options: .atomic)
    try JSONEncoder().encode(version).write(to: root.appendingPathComponent("version.json"), options: .atomic)
}

@Test func textModelConnectionsKeepLocalRequestsOnDeviceAndCloudKeysOnHTTPS() throws {
    #expect(throws: (any Error).self) { try TextModelConnection(baseURL: "http://example.com/v1").endpoint(location: .local) }
    #expect(throws: (any Error).self) { try TextModelConnection(baseURL: "http://example.com/v1").endpoint(location: .cloud) }
    #expect(throws: (any Error).self) { try TextModelConnection(baseURL: "https://key@example.com/v1").endpoint(location: .cloud) }
    #expect(try TextModelConnection(baseURL: "http://127.0.0.1:11434/v1").endpoint(location: .local).host == "127.0.0.1")
}

@Test func minutesSourcesKeepKnownGapsAfterARecognitionConnectionFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-minutes-gaps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let captions = LiveCaptionStore(directory: root.appendingPathComponent("captions"))
    var archive = LiveCaptionArchive(sessionID: UUID().uuidString.lowercased())
    archive.schemaVersion = 3
    archive.coverage = [CaptionCoverage(id: "enabled", start: 0, end: 30, source: .merged, feature: "transcription", state: "enabled")]
    archive.connections = [CaptionConnection(id: "failed", source: .merged, start: 0, end: 10, complete: false, state: "failed")]
    archive.segments = [LiveCaptionSegment(id: "captured", start: 0, end: 10, text: "已取得的原文", final: true)]
    try await captions.save(archive)
    let sources = try MeetingMinutesSources.load(archive.sessionID, store: TranscriptionStore(root: root.appendingPathComponent("transcription")), captions: captions)
    #expect(sources.partial)
    #expect(sources.missingIntervals == ["合并音源 00:00:10–00:00:30"])
}
