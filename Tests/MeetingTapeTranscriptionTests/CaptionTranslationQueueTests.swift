import Foundation
import Testing
@testable import MeetingTapeTranscription

private actor TranslationGate {
    var inputs: [String] = []
    var times: [ContinuousClock.Instant] = []
    private var releaseFirst = false

    func translate(_ text: String, target: String) async throws -> CaptionTranslation {
        inputs.append(text)
        times.append(.now)
        if text == "blocked" {
            while !releaseFirst { try await Task.sleep(for: .milliseconds(10)) }
        }
        return CaptionTranslation(targetLanguage: target, text: "译：" + text, state: .translated, provider: "fixture")
    }
    func release() { releaseFirst = true }
}

private func captionFixture(_ text: String, id: String, revision: Int = 1, final: Bool = true, source: TranscriptSource = .system) -> LiveCaptionSegment {
    LiveCaptionSegment(id: id, start: 0, end: 1, text: text, final: final, source: source, connectionID: source.rawValue, revision: revision)
}

private func submit(_ raw: LiveCaptionSegment, queue: CaptionTranslationQueue, transcription: Bool = true) async throws -> LiveCaptionArchive {
    var options = SubtitleOptions(); options.translation = true; options.transcription = transcription
    var visible = raw
    if !transcription { visible.text = "" }
    visible.translation = CaptionTranslation(targetLanguage: options.targetLanguage, state: .pending, provider: options.provider.rawValue)
    let connection = CaptionConnection(id: raw.source.rawValue, source: raw.source, start: 0, end: 1, complete: false, state: "running")
    return try await queue.receive(mode: .separate, connection: connection, segments: [visible], inputs: [raw], options: options)
}

@Test func finalTranslationPrecedesLatestDraftAcrossAudioSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root), id = UUID().uuidString.lowercased(), gate = TranslationGate()
    let queue = CaptionTranslationQueue(sessionID: id, store: store, translator: { text, target, _ in try await gate.translate(text, target: target) })
    _ = try await submit(captionFixture("blocked", id: "gate"), queue: queue)
    for _ in 0..<100 where await gate.inputs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.inputs == ["blocked"])
    _ = try await submit(captionFixture("old", id: "draft", final: false), queue: queue)
    _ = try await submit(captionFixture("latest", id: "draft", revision: 2, final: false), queue: queue)
    _ = try await submit(captionFixture("final", id: "final", source: .microphone), queue: queue)
    await gate.release(); try await queue.drain()
    #expect(await gate.inputs == ["blocked", "final", "latest"])
    let saved = try #require(try await store.load(id))
    #expect(saved.segments.first { $0.id == "draft" }?.targetText == "译：latest")
    #expect(saved.translationJobs.first { $0.input == "old" }?.state == .superseded)
    _ = try await submit(captionFixture("another draft", id: "other", final: false, source: .microphone), queue: queue)
    try await queue.drain()
    let times = await gate.times
    #expect(times[2].duration(to: times[3]) >= .seconds(1))
}

@Test func translationRetriesTransientFailuresTwiceAndKeepsEachAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root), id = UUID().uuidString.lowercased()
    let queue = CaptionTranslationQueue(sessionID: id, store: store, translator: { _, _, _ in throw URLError(.timedOut) })
    _ = try await submit(captionFixture("hello", id: "retry"), queue: queue)
    try await queue.drain()
    let saved = try #require(try await store.load(id)), job = try #require(saved.translationJobs.first)
    #expect(job.state == .failed && job.attempts.count == 3)
    #expect(Set(job.attempts.map(\.id)).count == 3)
    #expect(job.attempts.allSatisfy { $0.state == "failed" && $0.executionSeconds != nil && $0.usage == nil })
}

@Test func completionAfterRestartPreservesPrivateInputAndOriginalVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), store = LiveCaptionStore(directory: root)
    let first = CaptionTranslationQueue(sessionID: id, store: store, translator: { _, _, _ in
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    })
    _ = try await submit(captionFixture("private input", id: "only-translation"), queue: first, transcription: false)
    try await first.preserveUnfinished(); try await first.drain()
    let parent = try #require(try await store.load(id))
    #expect(parent.segments[0].text.isEmpty)
    let gate = TranslationGate(), reopenedStore = LiveCaptionStore(directory: root)
    let reopened = CaptionTranslationQueue(sessionID: id, store: reopenedStore, translator: { text, target, _ in try await gate.translate(text, target: target) })
    #expect(await gate.inputs.isEmpty)
    let operation = UUID().uuidString.lowercased()
    try await reopened.complete(operationID: operation)
    try await reopened.drain()
    try await reopened.complete(operationID: operation)
    try await reopened.drain()
    let saved = try #require(try await reopenedStore.load(id))
    #expect(saved.segments == parent.segments)
    #expect(saved.translationVersions.count == 1)
    #expect(await gate.inputs == ["private input"])
    let child = saved.viewingTranslationVersion(operation)
    #expect(child.segments[0].targetText == "译：private input")
    let export = TranscriptExportSnapshot(title: "fixture", versions: [TranscriptExportVersion(live: saved, versionID: operation)])
    let markdown = try export.markdown(primary: "live:" + operation)
    #expect(markdown.contains("译：private input"))
    #expect(!markdown.contains("原文：private input"))
    if let directory = ProcessInfo.processInfo.environment["MEETINGTAPE_VERIFICATION_ROOT"] {
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: destination.appendingPathComponent(id + ".json"), options: .atomic)
        try Data((id + "\n" + operation + "\n").utf8).write(to: destination.appendingPathComponent("ids.txt"), options: .atomic)
    }
}

@Test func waitingForTranslationsReportsAnUncommittedSuccessfulResponse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let retained = root.appendingPathExtension("retained")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: retained)
    }
    let id = UUID().uuidString.lowercased(), store = LiveCaptionStore(directory: root)
    let queue = CaptionTranslationQueue(sessionID: id, store: store, translator: { _, target, _ in
        try FileManager.default.moveItem(at: root, to: retained)
        try Data("unwritable archive directory".utf8).write(to: root)
        return CaptionTranslation(targetLanguage: target, text: "尚未提交的译文", state: .translated, provider: "fixture")
    })
    _ = try await submit(captionFixture("hello", id: "disk-failure"), queue: queue)
    await #expect(throws: TranslationFailure.self) { try await queue.drain() }
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: retained, to: root)
    let saved = try #require(try await store.load(id))
    #expect(saved.translationJobs[0].state == .running)
    #expect(saved.segments[0].targetText != "尚未提交的译文")
}

@Test func retranslatingCompletionIncludesSuccessfulInheritedSentences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), store = LiveCaptionStore(directory: root)
    let queue = CaptionTranslationQueue(sessionID: id, store: store, translator: { text, target, _ in
        if text == "sentence B" { throw TranscriptionFailure("permanent fixture failure") }
        return CaptionTranslation(targetLanguage: target, text: "旧A", state: .translated, provider: "fixture")
    })
    var options = SubtitleOptions(); options.translation = true
    let connection = CaptionConnection(id: "system", source: .system, start: 0, end: 1, complete: true, state: "completed")
    let inputs = [captionFixture("sentence A", id: "A"), captionFixture("sentence B", id: "B")]
    _ = try await queue.receive(mode: .separate, connection: connection, segments: inputs, inputs: inputs, options: options)
    try await queue.drain()
    let original = try #require(try await store.load(id))
    let gate = TranslationGate()
    let completion = CaptionTranslationQueue(sessionID: id, store: store, translator: { text, target, _ in try await gate.translate(text, target: target) })
    let second = try await completion.complete()
    try await completion.drain()
    let before = try #require(try await store.load(id)).viewingTranslationVersion(second)
    let third = try await completion.complete(parentID: second, includeCompleted: true)
    try await completion.drain()
    let saved = try #require(try await store.load(id))
    #expect(saved.segments == original.segments)
    #expect(saved.viewingTranslationVersion(second).segments == before.segments)
    #expect(Set(saved.translationJobs.filter { $0.versionID == third }.map(\.input)) == ["sentence A", "sentence B"])
    #expect(await gate.inputs.count == 3)
}
