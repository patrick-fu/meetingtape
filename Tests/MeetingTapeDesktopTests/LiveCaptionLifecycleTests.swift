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
    private(set) var resumedAt: Double?
    var simulateSourceFailure = false
    private var retryGate: CaptionGate?
    private var retryResult = true
    private var update: (@Sendable (LiveCaptionArchive) async -> Void)?
    private var finishOnCancel = false

    init(id: String, text: String, store: LiveCaptionStore) { self.id = id; self.text = text; self.store = store }
    func finish(_ value: SessionSnapshot) { finishing = true; Task { await stopGate.release() } }
    func cancel() async {
        cancelled = true; await stopGate.release()
        if finishOnCancel { await archiveGate.release(); try? await Task.sleep(for: .milliseconds(100)) }
    }
    func finishDuringCancellation() { finishOnCancel = true }
    func failOneSource() { simulateSourceFailure = true }
    func delayRetry(_ gate: CaptionGate, result: Bool) { retryGate = gate; retryResult = result }
    func publish(_ value: LiveCaptionArchive) async { await update?(value) }
    func retryFailed(at time: Double) async -> Bool { resumedAt = time; await retryGate?.wait(); return retryResult }
    func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        self.update = update
        started = true
        var document = (try? await store.load(id)) ?? LiveCaptionArchive(sessionID: id)
        loadedText = document.segments.map(\.text)
        if simulateSourceFailure {
            document.connections = [CaptionConnection(id: "failed", source: .system, start: 0, end: 1, complete: false, state: "failed"), CaptionConnection(id: "running", source: .microphone, start: 0, end: 1, complete: false, state: "running")]
            document.message = "部分音源字幕连接失败，录音继续。"
        }
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

private actor TailTranslationSession: LiveCaptionRunning {
    let queue: CaptionTranslationQueue
    let gate = CaptionGate()
    let sessionID: String
    private(set) var started = false
    private(set) var finishing = false
    init(queue: CaptionTranslationQueue, sessionID: String) { self.queue = queue; self.sessionID = sessionID }
    func finish(_ value: SessionSnapshot) { finishing = true }
    func cancel() { Task { await gate.release() } }
    func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive {
        started = true
        await gate.wait()
        var options = SubtitleOptions(); options.translation = true
        let segment = LiveCaptionSegment(id: "tail", start: 0, end: 1, text: "late final", final: true, connectionID: "tail", revision: 1)
        let connection = CaptionConnection(id: "tail", source: .merged, start: 0, end: 1, complete: true, state: "completed")
        return (try? await queue.receive(mode: .merged, connection: connection, segments: [segment], inputs: [segment], options: options)) ?? LiveCaptionArchive(sessionID: sessionID)
    }
}

@Test @MainActor
func waitingToQuitChecksTranslationsSubmittedByTheLastASRTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let retained = root.appendingPathExtension("retained")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: retained) }
    let store = LiveCaptionStore(directory: root)
    var snapshot = SessionSnapshot(recoveryPath: root.path); snapshot.state = .recording
    var service: TailTranslationSession?
    let model = LiveCaptionModel(enabled: true, store: store, translator: { _, target, _ in
        try FileManager.default.moveItem(at: root, to: retained)
        try Data("unwritable directory".utf8).write(to: root)
        return CaptionTranslation(targetLanguage: target, text: "未保存尾句", state: .translated, provider: "fixture")
    }) { value, _, _, queue in
        let session = TailTranslationSession(queue: queue, sessionID: value.sessionID)
        service = session; return session
    }
    model.observe(snapshot, fromStart: true)
    do {
        try await waitForCaption { await service?.started == true }
        let tail = try #require(service)
        snapshot.state = .completed; model.observe(snapshot)
        try await waitForCaption { await tail.finishing }
        let quitting = Task { await model.shutdown() }
        try await Task.sleep(for: .milliseconds(80))
        await tail.gate.release()
        let saved = await quitting.value
        try? await tail.queue.drain()
        #expect(!saved)
        #expect(model.message?.contains("未保存") == true)
    } catch {
        await service?.gate.release(); await model.shutdown(); throw error
    }
}

@Test @MainActor
func compactCaptionFollowsLongSourceRevisionWithoutReorderingArchive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-compact-source-\(UUID().uuidString)")
    let prior = UserDefaults.standard.object(forKey: "liveTranslationEnabled")
    defer {
        try? FileManager.default.removeItem(at: root)
        if let prior { UserDefaults.standard.set(prior, forKey: "liveTranslationEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "liveTranslationEnabled") }
    }
    let store = LiveCaptionStore(directory: root)
    var snapshot = SessionSnapshot(recoveryPath: root.path)
    snapshot.state = .recording; snapshot.recognitionMode = .separate
    let service = DelayedCaptionSession(id: snapshot.sessionID, text: "夹具", store: store)
    await service.archiveGate.release()
    let model = LiveCaptionModel(enabled: true, store: store, makeSession: { _, _, _, _ in service })
    model.setTranslationEnabled(true)
    do {
        model.observe(snapshot, fromStart: true)
        try await waitForCaption { model.currentLine == "夹具识别中" }
        var document = LiveCaptionArchive(sessionID: snapshot.sessionID)
        var system = LiveCaptionSegment(id: "system", start: 1, end: 2, text: "系统短句", final: false, source: .system)
        document.segments = [system]; document.updateRevision = 1
        await service.publish(document)
        let microphone = LiveCaptionSegment(id: "microphone", start: 2, end: 3, text: "麦克风短句", final: true, source: .microphone, translation: CaptionTranslation(targetLanguage: "en", text: "Microphone", state: .translated, provider: "fixture"))
        document.segments.append(microphone); document.updateRevision = 2
        await service.publish(document)
        #expect(model.currentLine == "麦克风短句")
        system.end = 10; system.text = "仍在更新的系统长句"; system.revision = 1
        system.translation = CaptionTranslation(targetLanguage: "en", text: "Ongoing system sentence", state: .translated, provider: "fixture")
        document.segments[0] = system; document.updateRevision = 3
        await service.publish(document)
        #expect(model.currentLine == "仍在更新的系统长句")
        #expect(model.latest?.source == .system)
        #expect(model.translationLine == "Ongoing system sentence")
        #expect(model.segments.map(\.source) == [.system, .microphone])
        await model.shutdown()
    } catch {
        await model.shutdown(); throw error
    }
}

@Test @MainActor
func failedLiveSourceCanReconnectWhileOtherSourceContinues() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-live-source-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var snapshot = SessionSnapshot(recoveryPath: root.path)
    snapshot.state = .recording; snapshot.elapsedSeconds = 30; snapshot.committedSeconds = 20; snapshot.recognitionMode = .separate
    let service = DelayedCaptionSession(id: snapshot.sessionID, text: "仍在录音", store: store)
    await service.archiveGate.release(); await service.failOneSource()
    let model = LiveCaptionModel(enabled: true, store: store, makeSession: { _, _, _, _ in service })
    model.observe(snapshot, fromStart: true)
    try await waitForCaption { model.canRetry }
    model.retry()
    try await waitForCaption { await service.resumedAt != nil }
    #expect(await service.resumedAt ?? 0 >= 30)
    #expect(await service.cancelled == false)
    await model.shutdown()
}

@Test @MainActor
func staleSourceRetryCannotRestartReplacementRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-stale-source-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LiveCaptionStore(directory: root)
    var first = SessionSnapshot(recoveryPath: root.path); first.state = .recording; first.recognitionMode = .separate
    var next = SessionSnapshot(recoveryPath: root.path); next.state = .recording
    let a = DelayedCaptionSession(id: first.sessionID, text: "旧任务", store: store)
    let b = DelayedCaptionSession(id: next.sessionID, text: "新任务", store: store)
    let gate = CaptionGate()
    await a.archiveGate.release(); await b.archiveGate.release()
    await a.failOneSource(); await a.delayRetry(gate, result: false)
    var creations = 0
    let model = LiveCaptionModel(enabled: true, store: store, makeSession: { value, _, _, _ in creations += 1; return value.sessionID == first.sessionID ? a : b })
    do {
        model.observe(first, fromStart: true)
        try await waitForCaption { model.canRetry }
        model.retry()
        try await waitForCaption { await a.resumedAt != nil }
        #expect(!model.canRetry)
        model.observe(next, fromStart: true)
        try await waitForCaption { await b.started }
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(creations == 2)
        #expect(await b.cancelled == false)
        #expect(model.sessionID == next.sessionID)
        await model.shutdown()
    } catch {
        await gate.release(); await model.shutdown(); throw error
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

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_MINUTES_LIFECYCLE_ENDPOINT"] != nil)) @MainActor
struct AutomaticMinutesLifecycle {
    @Test(.serialized, arguments: ["live", "post", "preserve", "resume"])
    func automaticNotesWaitForTailAndRespectQuit(_ mode: String) async throws {
        let library = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"]))
        _ = try #require(ProcessInfo.processInfo.environment["MEETINGTAPE_TRANSCRIPTION_DIR"])
        var settings = TextModelSettings()
        settings.local = TextModelConnection(baseURL: try #require(ProcessInfo.processInfo.environment["MEETINGTAPE_MINUTES_LIFECYCLE_ENDPOINT"]), model: "synthetic-minutes")
        try TextModelConfiguration().save(settings)
        let taskStore = try TranscriptionStore()
        var post = try taskStore.settings(); post.automatic = mode == "post"; try taskStore.saveSettings(post)
        let store = LiveCaptionStore()
        var snapshot = SessionSnapshot(recoveryPath: FileManager.default.temporaryDirectory.path)
        snapshot.state = .recording
        let service = DelayedCaptionSession(id: snapshot.sessionID, text: mode, store: store)
        let firstID = snapshot.sessionID
        var next = SessionSnapshot(recoveryPath: FileManager.default.temporaryDirectory.path)
        next.state = .recording
        let successor = DelayedCaptionSession(id: next.sessionID, text: "resume-next", store: store)
        let captions = LiveCaptionModel(enabled: true, store: store, makeSession: { value, _, _, _ in value.sessionID == firstID ? service : successor })
        let app = AppModel(liveCaptions: captions)
        let transcription = app.transcription
        let minutes = app.minutes
        do {
            captions.observe(snapshot, fromStart: true)
            try await waitForCaption { await service.started }
            snapshot.state = .completed; snapshot.elapsedSeconds = 1
            captions.observe(snapshot)
            try await waitForCaption { await service.finishing }
            if mode == "post" {
                var run = TranscriptRun(model: .qwen, revision: "fixture")
                run.sources[0].state = .succeeded
                let task = TranscriptionTask(id: UUID().uuidString, inputPath: "/synthetic.m4a", inputSHA256: "fixture", sessionID: snapshot.sessionID, duration: 1, createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(1)), primaryModel: .qwen, runs: [run])
                transcription.tasks = [task]
            } else { minutes.recordingCompleted(sessionID: snapshot.sessionID, at: Date()) }
            #expect(minutes.busy)
            #expect(try minutes.store.readSnapshot(sessionID: snapshot.sessionID).isEmpty)
            if mode == "preserve" || mode == "resume" {
                await service.finishDuringCancellation()
                let path = library.appendingPathComponent("LiveCaptions")
                let retained = path.appendingPathExtension("retained")
                if mode == "resume" {
                    try FileManager.default.moveItem(at: path, to: retained)
                    try Data("unwritable captions".utf8).write(to: path)
                }
                let saved = await app.flush(preserveTranslations: true)
                if mode == "resume" {
                    try FileManager.default.removeItem(at: path)
                    try FileManager.default.moveItem(at: retained, to: path)
                }
                #expect(saved == (mode == "preserve"))
                #expect(try minutes.lastRun(snapshot.sessionID)?.state == "interrupted")
                await service.archiveGate.release()
                try await waitForCaption { !minutes.busy }
                #expect(try minutes.store.readSnapshot(sessionID: snapshot.sessionID).isEmpty)
                if mode == "resume" {
                    await successor.archiveGate.release()
                    captions.observe(next, fromStart: true)
                    try await waitForCaption { await successor.started }
                    next.state = .completed; next.elapsedSeconds = 1; captions.observe(next)
                    minutes.recordingCompleted(sessionID: next.sessionID, at: Date())
                    try await waitForCaption { (try? minutes.store.readSnapshot(sessionID: next.sessionID).count) == 1 }
                    #expect(try minutes.lastRun(next.sessionID)?.state == "succeeded")
                }
            } else {
                var finished = false
                let quitting = Task { let saved = await app.flush(); finished = true; return saved }
                try await Task.sleep(for: .milliseconds(80))
                #expect(!finished)
                await service.archiveGate.release()
                #expect(await quitting.value)
                let versions = try minutes.store.readSnapshot(sessionID: snapshot.sessionID)
                #expect(versions.count == 1)
                #expect(versions.first?.citations.map(\.text) == [mode + "尾句"])
                #expect(versions.first?.body.contains("尾句已归档") == true)
                #expect(try minutes.lastRun(snapshot.sessionID)?.state == "succeeded")
            }
            await captions.shutdown()
        } catch {
            await service.archiveGate.release(); await captions.shutdown(); _ = await minutes.finish(preserve: true); throw error
        }
    }
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
    let model = LiveCaptionModel(enabled: true, store: store, makeSession: { value, _, _, _ in value.sessionID == first.sessionID ? a : b })
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
    var snapshot = SessionSnapshot(recoveryPath: root.path); snapshot.state = .recording; snapshot.committedSeconds = 1; snapshot.elapsedSeconds = 9
    let a = DelayedCaptionSession(id: snapshot.sessionID, text: "甲", store: store)
    let b = DelayedCaptionSession(id: snapshot.sessionID, text: "乙", store: store)
    await b.archiveGate.release()
    var count = 0
    var offsets: [Double] = []
    let model = LiveCaptionModel(enabled: true, store: store, makeSession: { _, offset, _, _ in offsets.append(offset); count += 1; return count == 1 ? a : b })
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
        #expect(offsets.count == 2 && offsets[1] >= snapshot.elapsedSeconds)
        await model.shutdown()
    } catch {
        await a.archiveGate.release(); await b.archiveGate.release(); await model.shutdown()
        throw error
    }
}
