import Foundation
import Testing
@testable import MeetingTapeCore
@testable import MeetingTapeDesktop
@testable import MeetingTapeTranscription

private actor CaptionGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

private actor DelayedCaptionSession: LiveCaptionRunning {
    let id: String
    let text: String
    let store: LiveCaptionStore
    let archiveGate = CaptionGate()
    private let stopGate = CaptionGate()
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var finishing = false
    private(set) var loadedText: [String]?

    init(id: String, text: String, store: LiveCaptionStore) { self.id = id; self.text = text; self.store = store }
    func finish(_ value: SessionSnapshot) { finishing = true; Task { await stopGate.release() } }
    func cancel() { cancelled = true; Task { await stopGate.release() } }
    func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        started = true
        var document = (try? await store.load(id)) ?? LiveCaptionArchive(sessionID: id)
        loadedText = document.segments.map(\.text)
        document.segments.append(LiveCaptionSegment(id: text, start: 0, end: 1, text: text + "识别中", final: false))
        await update(document)
        await stopGate.wait(); await archiveGate.wait()
        document.segments[document.segments.count - 1].text = text + (cancelled ? "未定稿" : "尾句")
        document.segments[document.segments.count - 1].final = !cancelled
        document.complete = !cancelled
        try? await store.save(document)
        await update(document)
        return document
    }
}

@MainActor
private func waitForCaption(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "LiveCaptionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "字幕时序未在期限内完成"])
}

@Test @MainActor
func newRecordingKeepsPreviousCaptionFinalizationAndOnlyUpdatesItsOwnWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-jobs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var first = SessionSnapshot(recoveryPath: root.path); first.state = .recording
    var next = SessionSnapshot(recoveryPath: root.path); next.state = .recording
    let a = DelayedCaptionSession(id: first.sessionID, text: "甲", store: store)
    let b = DelayedCaptionSession(id: next.sessionID, text: "乙", store: store)
    await b.archiveGate.release()
    let model = LiveCaptionModel(enabled: true, store: store) { value, _, _ in value.sessionID == first.sessionID ? a : b }
    do {
        model.observe(first, fromStart: true)
        try await waitForCaption { await a.started }
        var completed = first; completed.state = .completed
        model.observe(completed)
        try await waitForCaption { await a.finishing }
        model.observe(next, fromStart: true)
        try await waitForCaption { model.currentLine == "乙识别中" }
        #expect(await a.cancelled == false)
        await a.archiveGate.release()
        try await waitForCaption { (try? await store.load(first.sessionID))?.complete == true }
        #expect(model.sessionID == next.sessionID)
        #expect(model.currentLine == "乙识别中")
        #expect(try await store.load(first.sessionID)?.segments.last?.text == "甲尾句")
        await model.shutdown()
    } catch {
        await a.archiveGate.release(); await b.archiveGate.release(); await model.shutdown()
        throw error
    }
}

@Test @MainActor
func reconnectWaitsForThePreviousArchiveBeforeReadingItsPrefix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-reconnect-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var snapshot = SessionSnapshot(recoveryPath: root.path); snapshot.state = .recording; snapshot.committedSeconds = 1
    let a = DelayedCaptionSession(id: snapshot.sessionID, text: "甲", store: store)
    let b = DelayedCaptionSession(id: snapshot.sessionID, text: "乙", store: store)
    await b.archiveGate.release()
    var count = 0
    let model = LiveCaptionModel(enabled: true, store: store) { _, _, _ in count += 1; return count == 1 ? a : b }
    do {
        model.observe(snapshot, fromStart: true)
        try await waitForCaption { model.currentLine == "甲识别中" }
        model.observe(nil); model.observe(snapshot)
        try await waitForCaption { await a.cancelled }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await b.started == false)
        await a.archiveGate.release()
        try await waitForCaption { await b.loadedText != nil }
        #expect(await b.loadedText == ["甲未定稿"])
        await model.shutdown()
    } catch {
        await a.archiveGate.release(); await b.archiveGate.release(); await model.shutdown()
        throw error
    }
}
