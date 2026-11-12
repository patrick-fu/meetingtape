import Foundation

public enum CaptionTranslationJobState: String, Codable, Sendable {
    case queued, running, succeeded, failed, superseded, interrupted
    public var unfinished: Bool { self == .queued || self == .running || self == .interrupted || self == .failed }
}

public struct CaptionTranslationAttempt: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public var startedAt: Date
    public var finishedAt: Date?
    public var queueSeconds: Double
    public var executionSeconds: Double?
    public var state: String = "running"
    public var usage: [String: Int]?
}

public struct CaptionTranslationJob: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public var versionID: String?
    public var runID: String
    public var segmentID: String
    public var revision: Int
    public var source: TranscriptSource
    public var input: String
    public var final: Bool
    public var targetLanguage: String
    public var provider: SubtitleTranslationProvider
    public var state: CaptionTranslationJobState = .queued
    public var queuedAt = Date()
    public var readyAt = Date()
    public var attempts: [CaptionTranslationAttempt] = []
    public var result: CaptionTranslation?
    public var message: String?
}

public struct CaptionTranslationVersion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var parentID: String?
    public var createdAt = Date()
    public var segments: [LiveCaptionSegment]
    public var title: String
}

public struct TranslationFailure: LocalizedError, Sendable {
    public var message: String
    public var transient: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, transient: Bool = false) { self.message = message; self.transient = transient }
    static func canRetry(_ error: any Error) -> Bool {
        if let failure = error as? TranslationFailure { return failure.transient }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}

public actor CaptionTranslationQueue {
    private let sessionID: String
    private let store: LiveCaptionStore
    private let translator: @Sendable (CaptionTranslationJob) async throws -> CaptionTranslation
    private var update: @Sendable (LiveCaptionArchive) async -> Void
    public nonisolated let runID = UUID().uuidString.lowercased()
    private var worker: Task<Void, Never>?
    private var request: Task<CaptionTranslation, any Error>?
    private var activeJobID: String?
    private var lastDraft: ContinuousClock.Instant?
    private var stopped = false
    private var wakeRevision = 0
    private var persistenceFailure: String?

    public init(sessionID: String, store: LiveCaptionStore, translator: CaptionTranslate? = nil, update: @escaping @Sendable (LiveCaptionArchive) async -> Void = { _ in }) {
        self.sessionID = sessionID; self.store = store; self.update = update
        if let translator { self.translator = { try await translator($0.input, $0.targetLanguage, $0.provider) } }
        else { self.translator = { try await TextTranslation.translate($0.input, target: $0.targetLanguage, provider: $0.provider, credential: nil, requestID: $0.attempts.last?.id) } }
    }

    func observe(_ update: @escaping @Sendable (LiveCaptionArchive) async -> Void) { self.update = update }

    func receive(mode: RecognitionMode, connection: CaptionConnection, segments: [LiveCaptionSegment], inputs: [LiveCaptionSegment], options: SubtitleOptions) async throws -> LiveCaptionArchive {
        guard !stopped else { throw CancellationError() }
        let value = try await store.updateConnection(sessionID, mode: mode, connection: connection, segments: segments, translationInputs: inputs, options: options, runID: runID)
        wakeRevision += 1
        if let activeJobID, value.translationJobs.first(where: { $0.id == activeJobID })?.state == .superseded { request?.cancel() }
        await update(value)
        startWorker()
        return value
    }

    @discardableResult public func complete(parentID: String? = nil, operationID: String = UUID().uuidString.lowercased(), includeCompleted: Bool = false) async throws -> String {
        guard !stopped else { throw CancellationError() }
        let value = try await store.beginTranslationCompletion(sessionID, parentID: parentID, operationID: operationID, runID: runID, includeCompleted: includeCompleted)
        persistenceFailure = nil
        wakeRevision += 1
        await update(value)
        startWorker()
        return operationID
    }

    public func drain() async throws {
        while let worker { await worker.value }
        if let persistenceFailure { throw TranslationFailure(persistenceFailure) }
    }

    public func preserveUnfinished() async throws {
        stopped = true
        let value = try await store.interruptTranslations(sessionID, runID: runID)
        request?.cancel()
        await update(value)
    }

    private func startWorker() {
        guard !stopped, worker == nil else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        defer { worker = nil; request = nil; activeJobID = nil }
        while !stopped {
            do {
                let observedWake = wakeRevision
                guard let archive = try await store.load(sessionID) else { return }
                let pending = archive.translationJobs.filter { $0.runID == runID && $0.state == .queued }
                if pending.isEmpty { if observedWake != wakeRevision { continue }; return }
                let now = Date()
                let draftReady = lastDraft.map { $0.duration(to: .now) >= .seconds(1) } ?? true
                let ready = pending.filter { $0.readyAt <= now && ($0.final || draftReady) }
                guard let next = ready.sorted(by: { $0.final != $1.final ? $0.final : $0.queuedAt < $1.queuedAt }).first else {
                    try await Task.sleep(for: .milliseconds(50)); continue
                }
                guard let job = try await store.startTranslation(sessionID, id: next.id, runID: runID) else { continue }
                if !job.final { lastDraft = .now }
                activeJobID = job.id
                let translator = self.translator
                let began = ContinuousClock.now
                let task = Task { try await translator(job) }
                request = task
                do {
                    var response = try await task.value
                    if response.state == .sameLanguage { response.text = job.input }
                    let elapsed = began.duration(to: .now).secondsValue
                    let value = try await store.finishTranslation(sessionID, job: job, response: response, elapsed: elapsed)
                    await update(value)
                } catch {
                    let elapsed = began.duration(to: .now).secondsValue
                    let value = try await store.failTranslation(sessionID, job: job, error: error, elapsed: elapsed)
                    await update(value)
                }
                activeJobID = nil; request = nil
            } catch {
                persistenceFailure = "译文任务未保存：\(error.localizedDescription)"
                if var value = try? await store.load(sessionID) {
                    value.message = persistenceFailure
                    await update(value)
                }
                return
            }
        }
    }
}

extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

extension LiveCaptionArchive {
    public func viewingTranslationVersion(_ id: String?) -> Self {
        guard let id, let version = translationVersions.first(where: { $0.id == id }) else { return self }
        var value = self
        value.segments = version.segments
        value.translationJobs = translationJobs.filter { $0.versionID == id }
        value.translationVersions = []
        value.refreshCompletion()
        return value
    }

    mutating func enqueueTranslations(_ inputs: [LiveCaptionSegment], options: SubtitleOptions, runID: String) {
        for raw in inputs where !raw.text.isEmpty {
            guard !translationJobs.contains(where: { $0.versionID == nil && $0.segmentID == raw.id && $0.revision == raw.revision && $0.targetLanguage == options.targetLanguage && $0.provider == options.provider }) else { continue }
            for i in translationJobs.indices where translationJobs[i].versionID == nil && translationJobs[i].segmentID == raw.id && !translationJobs[i].final && [.queued, .running].contains(translationJobs[i].state) {
                translationJobs[i].state = .superseded
            }
            translationJobs.append(CaptionTranslationJob(runID: runID, segmentID: raw.id, revision: raw.revision, source: raw.source, input: raw.text, final: raw.final, targetLanguage: options.targetLanguage, provider: options.provider))
        }
    }

    mutating func projectTranslations() {
        var jobs: [TranslationProjectionKey: CaptionTranslationJob] = [:]
        for job in translationJobs { jobs[TranslationProjectionKey(versionID: job.versionID, segmentID: job.segmentID, revision: job.revision)] = job }
        for i in segments.indices { Self.projectTranslation(into: &segments[i], versionID: nil, jobs: jobs) }
        for v in translationVersions.indices {
            for i in translationVersions[v].segments.indices {
                var segment = translationVersions[v].segments[i]
                Self.projectTranslation(into: &segment, versionID: translationVersions[v].id, jobs: jobs)
                translationVersions[v].segments[i] = segment
            }
        }
    }

    private static func projectTranslation(into segment: inout LiveCaptionSegment, versionID: String?, jobs: [TranslationProjectionKey: CaptionTranslationJob]) {
        guard let job = jobs[TranslationProjectionKey(versionID: versionID, segmentID: segment.id, revision: segment.revision)] else { return }
        if job.state == .succeeded, let result = job.result { segment.translation = result; return }
        guard job.state != .superseded else { return }
        let old = segment.translation?.targetLanguage == job.targetLanguage ? segment.translation?.text : nil
        let state: CaptionTranslationState = job.state == .failed ? .failed : job.state == .interrupted ? .interrupted : .pending
        segment.translation = CaptionTranslation(targetLanguage: job.targetLanguage, text: old, state: state, provider: job.provider.rawValue)
    }

    mutating func refreshCompletion() {
        partial = connections.contains { $0.state == "failed" || $0.state == "cancelled" } || coverage.contains { ($0.state == "disabled" || $0.state == "unknown") && $0.end > $0.start } || segments.contains { $0.translation?.state == .failed || $0.translation?.state == .interrupted }
        complete = !partial && connections.allSatisfy(\.complete) && segments.allSatisfy { $0.final && $0.translation?.state != .pending }
        message = connections.contains { $0.state == "failed" } ? "部分音源字幕连接失败，录音继续。" : nil
        if message == nil, segments.contains(where: { $0.translation?.state == .failed || $0.translation?.state == .interrupted }) { message = "部分译文未完成，已保留取得的字幕。" }
    }
}

private struct TranslationProjectionKey: Hashable {
    var versionID: String?
    var segmentID: String
    var revision: Int
}

extension LiveCaptionStore {
    func startTranslation(_ sessionID: String, id: String, runID: String) throws -> CaptionTranslationJob? {
        guard var value = try load(sessionID), let i = value.translationJobs.firstIndex(where: { $0.id == id && $0.runID == runID && $0.state == .queued }) else { return nil }
        value.translationJobs[i].state = .running
        value.translationJobs[i].attempts.append(CaptionTranslationAttempt(startedAt: Date(), queueSeconds: max(0, Date().timeIntervalSince(value.translationJobs[i].readyAt))))
        value.updateRevision += 1
        try save(value)
        return value.translationJobs[i]
    }

    func finishTranslation(_ sessionID: String, job: CaptionTranslationJob, response: CaptionTranslation, elapsed: Double) throws -> LiveCaptionArchive {
        try changeTranslation(sessionID, job: job) { current in
            if let a = current.attempts.indices.last {
                current.attempts[a].finishedAt = Date(); current.attempts[a].executionSeconds = elapsed
                current.attempts[a].usage = response.usage; current.attempts[a].state = "succeeded"
            }
            guard current.state == .running else { return }
            current.state = .succeeded; current.result = response; current.message = nil
        }
    }

    func failTranslation(_ sessionID: String, job: CaptionTranslationJob, error: any Error, elapsed: Double) throws -> LiveCaptionArchive {
        try changeTranslation(sessionID, job: job) { current in
            if let a = current.attempts.indices.last {
                current.attempts[a].finishedAt = Date(); current.attempts[a].executionSeconds = elapsed
                current.attempts[a].state = error is CancellationError ? "cancelled" : "failed"
            }
            guard current.state == .running else { return }
            if error is CancellationError { current.state = .interrupted }
            else if TranslationFailure.canRetry(error), current.attempts.count < 3 {
                current.state = .queued
                current.readyAt = Date().addingTimeInterval(current.attempts.count == 1 ? 0.5 : 1)
            } else { current.state = .failed }
            current.message = error.localizedDescription
        }
    }

    private func changeTranslation(_ sessionID: String, job: CaptionTranslationJob, change: (inout CaptionTranslationJob) -> Void) throws -> LiveCaptionArchive {
        guard var value = try load(sessionID), let i = value.translationJobs.firstIndex(where: { $0.id == job.id && $0.attempts.last?.id == job.attempts.last?.id }) else { throw TranscriptionFailure("译文任务不存在。") }
        change(&value.translationJobs[i])
        value.projectTranslations(); value.refreshCompletion(); value.updateRevision += 1
        try save(value)
        return value
    }

    func interruptTranslations(_ sessionID: String, runID: String) throws -> LiveCaptionArchive {
        var value = try load(sessionID) ?? LiveCaptionArchive(sessionID: sessionID)
        value.schemaVersion = 3
        if !value.translationSealedRuns.contains(runID) { value.translationSealedRuns.append(runID) }
        for i in value.translationJobs.indices where value.translationJobs[i].runID == runID && [.queued, .running].contains(value.translationJobs[i].state) { value.translationJobs[i].state = .interrupted }
        for i in value.connections.indices where !["completed", "cancelled", "failed"].contains(value.connections[i].state) { value.connections[i].state = "cancelled" }
        value.projectTranslations(); value.refreshCompletion(); value.updateRevision += 1
        try save(value)
        return value
    }

    func beginTranslationCompletion(_ sessionID: String, parentID: String?, operationID: String, runID: String, includeCompleted: Bool) throws -> LiveCaptionArchive {
        guard UUID(uuidString: operationID) != nil, var value = try load(sessionID) else { throw TranscriptionFailure("没有可补齐的字幕归档。") }
        if value.translationVersions.contains(where: { $0.id == operationID }) { return value }
        if let parentID, !value.translationVersions.contains(where: { $0.id == parentID }) { throw TranscriptionFailure("原字幕版本不存在。") }
        let parent = value.viewingTranslationVersion(parentID)
        var lineage: [String?] = [parentID]
        var ancestor = parentID
        while let id = ancestor, let version = value.translationVersions.first(where: { $0.id == id }), !lineage.contains(version.parentID) {
            lineage.append(version.parentID); ancestor = version.parentID
        }
        var jobs: [CaptionTranslationJob] = []
        for segment in parent.segments {
            guard includeCompleted || segment.translation?.state == .pending || segment.translation?.state == .failed || segment.translation?.state == .interrupted else { continue }
            guard var job = lineage.lazy.compactMap({ ancestor in value.translationJobs.last { $0.versionID == ancestor && $0.segmentID == segment.id && $0.revision == segment.revision } }).first, !job.input.isEmpty else { continue }
            job.id = UUID().uuidString.lowercased(); job.versionID = operationID; job.runID = runID
            job.state = .queued; job.attempts = []; job.result = nil; job.message = nil; job.queuedAt = Date(); job.readyAt = Date()
            jobs.append(job)
        }
        guard !jobs.isEmpty else { throw TranscriptionFailure("此版本没有可恢复的翻译输入。") }
        value.translationVersions.append(CaptionTranslationVersion(id: operationID, parentID: parentID, segments: parent.segments, title: "字幕译文 \(value.translationVersions.count + 2)"))
        value.translationJobs += jobs
        value.schemaVersion = 3; value.projectTranslations(); value.updateRevision += 1
        try save(value)
        return value
    }
}
