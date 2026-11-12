import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test func captionDisplayClocksStayWithTheirProducerAndKeepTheFirstPaint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-display-clocks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var archive = LiveCaptionArchive(sessionID: UUID().uuidString.lowercased())
    archive.schemaVersion = 3
    archive.recognitionObservations = [
        CaptionRecognitionObservation(id: "first", producerID: CaptionObservationClock.producerID, connectionID: "connection", segmentID: "segment", revision: 1, source: .system, provider: .senseVoice, first: true, final: false, start: 0, end: 1, audioReadUptime: 100, receivedUptime: 101, receivedAt: Date()),
        CaptionRecognitionObservation(id: "final", producerID: CaptionObservationClock.producerID, connectionID: "connection", segmentID: "segment", revision: 2, source: .system, provider: .senseVoice, first: false, final: true, start: 0, end: 5, audioReadUptime: 105, receivedUptime: 106, receivedAt: Date()),
        CaptionRecognitionObservation(id: "old", producerID: "another-process", connectionID: "old", segmentID: "old", revision: 1, source: .microphone, provider: .doubao, first: true, final: true, start: 0, end: 5, audioReadUptime: 100, receivedUptime: 101, receivedAt: Date()),
        CaptionRecognitionObservation(id: "unpainted", producerID: CaptionObservationClock.producerID, connectionID: "connection", segmentID: "replaced", revision: 1, source: .system, provider: .senseVoice, first: true, final: false, start: 0, end: 1, audioReadUptime: 100, receivedUptime: 101, receivedAt: Date()),
        CaptionRecognitionObservation(id: "replacement", producerID: CaptionObservationClock.producerID, connectionID: "connection", segmentID: "replaced", revision: 2, source: .system, provider: .senseVoice, first: false, final: true, start: 0, end: 2, audioReadUptime: 100.2, receivedUptime: 101.1, receivedAt: Date(), displayedUptime: 101.2, displayedAt: Date())
    ]
    var attempt = CaptionTranslationAttempt(startedAt: Date(), queueSeconds: 0.5)
    attempt.state = "running"
    var job = CaptionTranslationJob(runID: "run", segmentID: "segment", revision: 2, source: .system, input: "private recovery text", final: true, targetLanguage: "en", provider: .local)
    job.state = .running; job.attempts = [attempt]
    archive.translationJobs = [job]
    try await store.save(archive)
    _ = try await store.finishTranslation(archive.sessionID, job: job, response: CaptionTranslation(targetLanguage: "en", text: "translated", state: .translated, provider: "fixture"), elapsed: 1, receivedAt: Date(), receivedUptime: 107.5)
    #expect(try await store.acknowledgeDisplay(archive.sessionID, segmentID: "segment", revision: 1, original: true, translation: false, at: Date(), uptime: 101.5))
    #expect(try await store.acknowledgeDisplay(archive.sessionID, segmentID: "segment", revision: 2, original: true, translation: false, at: Date(), uptime: 109))
    #expect(try await store.acknowledgeDisplay(archive.sessionID, segmentID: "segment", revision: 2, original: false, translation: true, at: Date(), uptime: 110))
    #expect(try await !store.acknowledgeDisplay(archive.sessionID, segmentID: "segment", revision: 1, original: true, translation: false, at: Date(), uptime: 999))
    #expect(try await !store.acknowledgeDisplay(archive.sessionID, segmentID: "old", revision: 1, original: true, translation: false, at: Date(), uptime: 111))
    let stats = CaptionRunStatistics(archive: try #require(await store.load(archive.sessionID)))
    let recognition = try #require(stats.recognitionGroups.first { $0.provider == .senseVoice })
    #expect(recognition.firstDisplaySeconds.n == 2 && recognition.firstDisplaySeconds.p95 == 1.5 && recognition.finalDisplaySeconds.p95 == 4)
    #expect(stats.groups.first?.displaySeconds.p50 == 2.5)
    #expect(stats.groups.first?.audioToDisplaySeconds.p50 == 5)
    #expect(stats.recognitionGroups.first { $0.provider == .doubao }?.finalDisplaySeconds.n == 0)
    #expect(stats.markdown().contains("1.500 s") && stats.markdown().contains("5.000 s"))
    #expect(!String(decoding: try JSONEncoder().encode(stats), as: UTF8.self).contains("private recovery text"))
}

@Test func captionStatisticsUseSuccessfulAttemptsAndNearestRank() throws {
    var archive = LiveCaptionArchive(sessionID: "fixture")
    var job = CaptionTranslationJob(runID: "run", segmentID: "segment", revision: 1, source: .system, input: "private", final: true, targetLanguage: "zh", provider: .local)
    for value in [1.0, 2.0, 3.0, 4.0] {
        var attempt = CaptionTranslationAttempt(startedAt: Date(), queueSeconds: value)
        attempt.state = "succeeded"
        attempt.executionSeconds = value * 2
        job.attempts.append(attempt)
    }
    var failed = CaptionTranslationAttempt(startedAt: Date(), queueSeconds: 100)
    failed.state = "failed"
    job.attempts.append(failed)
    archive.translationJobs = [job]
    let stats = CaptionRunStatistics(archive: archive)
    let group = try #require(stats.groups.first)
    #expect(group.queueSeconds.n == 4)
    #expect(group.queueSeconds.p50 == 2)
    #expect(group.queueSeconds.p95 == 4)
    #expect(group.executionSeconds.p50 == 4)
    #expect(group.failed == 1)
    #expect(group.retries == 4)
    #expect(stats.attempts.last?.usage == nil)
    #expect(!String(decoding: try JSONEncoder().encode(stats), as: UTF8.self).contains("private"))
    #expect(CaptionRunStatistics(archive: archive, versionID: "other").groups.isEmpty)
}
