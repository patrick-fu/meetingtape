import Combine
import Foundation
import MeetingTapeTranscription

struct MinutesRun: Codable, Sendable {
    var sessionID: String
    var state: String
    var queuedAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var sourceFingerprint: String
    var provider: String
    var model: String
    var versionID: String?
    var message: String?
}

private struct MinutesRunFiles {
    private let directory: URL
    init() {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        directory = library.appendingPathComponent("MeetingMinutesRuns")
    }
    func load(_ sessionID: String) throws -> MinutesRun? {
        let file = try path(sessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw TranscriptionFailure("纪要执行记录过大。") }
        let run = try JSONDecoder().decode(MinutesRun.self, from: Data(contentsOf: file))
        guard run.sessionID == sessionID else { throw TranscriptionFailure("纪要执行记录与录音不匹配。") }
        return run
    }
    func save(_ run: MinutesRun) throws {
        try TranscriptionStore.directory(directory)
        let path = try path(run.sessionID)
        try JSONEncoder().encode(run).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func path(_ sessionID: String) throws -> URL {
        guard let id = UUID(uuidString: sessionID) else { throw TranscriptionFailure("纪要的录音标识无效。") }
        return directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
}

@MainActor
final class MeetingMinutesModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var busySessionIDs: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    let store = MeetingMinutesStore()
    let terms = ConfirmedTermStore()
    private let runs = MinutesRunFiles()
    private var jobs: [String: Task<MeetingMinutesVersion, any Error>] = [:]
    private var subscription: AnyCancellable?
    private var considered: Set<String> = []
    private var persistenceFailures: Set<String> = []
    private var committingSessions: Set<String> = []
    private let captions: LiveCaptionModel
    private var preparations: [String: Task<Void, Never>] = [:]
    private var acceptingAutomatic = true
    private var preserving = false

    init(transcription: TranscriptionModel, captions: LiveCaptionModel) {
        self.captions = captions
        subscription = transcription.$tasks.sink { [weak self] tasks in self?.considerAutomatic(tasks) }
    }

    var busy: Bool { !jobs.isEmpty || !preparations.isEmpty }
    func lastRun(_ sessionID: String) throws -> MinutesRun? {
        guard var run = try runs.load(sessionID) else { return nil }
        if jobs[sessionID] == nil, preparations[sessionID] == nil, ["queued", "running"].contains(run.state) {
            run.state = "interrupted"; run.finishedAt = Date(); try runs.save(run)
        }
        return run
    }
    func refresh() { revision += 1 }

    func generate(sessionID: String, parentID: String? = nil) async throws -> MeetingMinutesVersion {
        if let job = jobs[sessionID] { return try await job.value }
        let settings = try TextModelConfiguration().load()
        guard settings.configured else { throw TranscriptionFailure("请先在设置中选择纪要模型。") }
        let sources = try MeetingMinutesSources.load(sessionID)
        guard !sources.citations.isEmpty else { throw TranscriptionFailure("还没有可用于生成纪要的转写正文。") }
        let fingerprint = try MeetingMinutesGenerator.fingerprint(sources.citations)
        let queued = MinutesRun(sessionID: sessionID, state: "queued", sourceFingerprint: fingerprint, provider: settings.provider.rawValue, model: settings.connection.model)
        try runs.save(queued)
        errors.removeValue(forKey: sessionID); persistenceFailures.remove(sessionID)
        let previous = Array(jobs.values)
        busySessionIDs.insert(sessionID)
        let job = Task { [self] in
            var run = queued
            do {
                for previous in previous { _ = try? await previous.value }
                try Task.checkCancellation()
                run.state = "running"; run.startedAt = Date(); try runs.save(run)
                let glossary = try terms.effective(recordingID: sessionID)
                let version = try await MeetingMinutesGenerator.generate(sessionID: sessionID, citations: sources.citations, partial: sources.partial, provider: settings.provider.rawValue, model: settings.connection.model, language: settings.language, confirmedTerms: glossary.terms, missingIntervals: sources.missingIntervals) { system, user in
                    try await TextModelClient.generate(system: system, user: user, settings: settings)
                }
                try Task.checkCancellation()
                committingSessions.insert(sessionID)
                defer { committingSessions.remove(sessionID) }
                let stored = try await store.append(version, parentID: parentID)
                run.state = "succeeded"; run.versionID = stored.id; run.finishedAt = Date()
                try runs.save(run)
                return stored
            } catch {
                if Task.isCancelled { throw CancellationError() }
                run.state = error is CancellationError ? "interrupted" : "failed"
                run.message = error.localizedDescription; run.finishedAt = Date()
                do { try runs.save(run) }
                catch { persistenceFailures.insert(sessionID) }
                throw error
            }
        }
        jobs[sessionID] = job
        defer { jobs.removeValue(forKey: sessionID); busySessionIDs.remove(sessionID); revision += 1 }
        do { return try await job.value }
        catch is CancellationError { errors.removeValue(forKey: sessionID); throw CancellationError() }
        catch { errors[sessionID] = error.localizedDescription; throw error }
    }

    func edit(sessionID: String, body: String, parentID: String) async throws -> MeetingMinutesVersion {
        let version = try await store.edit(sessionID: sessionID, body: body, parentID: parentID)
        revision += 1
        return version
    }

    @discardableResult func cancel(_ sessionID: String) -> Bool {
        guard jobs[sessionID] != nil || preparations[sessionID] != nil else { return true }
        guard !committingSessions.contains(sessionID) else { errors[sessionID] = "纪要正在保存。"; return false }
        do {
            guard var run = try runs.load(sessionID) else { throw TranscriptionFailure("纪要执行记录不存在。") }
            guard ["queued", "running"].contains(run.state) else { return true }
            run.state = "interrupted"; run.finishedAt = Date(); try runs.save(run)
            preparations[sessionID]?.cancel(); jobs[sessionID]?.cancel(); return true
        } catch { errors[sessionID] = error.localizedDescription; persistenceFailures.insert(sessionID); return false }
    }

    func prepareForExit(preserve: Bool) -> Bool {
        acceptingAutomatic = false
        preserving = preserve
        if preserve {
            var saved = true
            for sessionID in Set(jobs.keys).union(preparations.keys) { if !cancel(sessionID) { saved = false } }
            return saved
        }
        return true
    }

    func resumeAfterCancelledExit() { acceptingAutomatic = true; preserving = false }

    func finish(preserve: Bool) async -> Bool {
        let prepared = prepareForExit(preserve: preserve)
        if preserve { return prepared }
        for preparation in Array(preparations.values) { await preparation.value }
        for job in Array(jobs.values) { _ = try? await job.value }
        return prepared && persistenceFailures.isEmpty
    }

    func recordingCompleted(sessionID: String, at date: Date) {
        guard acceptingAutomatic, let settings = try? TextModelConfiguration().load(), settings.automatic,
              settings.configured, let since = settings.automaticSince, date >= since,
              (try? TranscriptionStore().settings().automatic) == false else { return }
        prepareAutomatic(sessionID, settings: settings)
    }

    private func considerAutomatic(_ tasks: [TranscriptionTask]) {
        guard acceptingAutomatic, let settings = try? TextModelConfiguration().load(), settings.automatic, settings.configured, let since = settings.automaticSince else { return }
        let eligible = tasks.filter { $0.finished && $0.sessionID != nil && (ISO8601DateFormatter().date(from: $0.createdAt) ?? .distantPast) >= since }
        for id in Set(eligible.compactMap(\.sessionID)) where !considered.contains(id) && jobs[id] == nil {
            guard !tasks.contains(where: { $0.sessionID == id && !$0.finished }) else { continue }
            prepareAutomatic(id, settings: settings)
        }
    }

    private func prepareAutomatic(_ sessionID: String, settings: TextModelSettings) {
        guard !considered.contains(sessionID), preparations[sessionID] == nil, jobs[sessionID] == nil else { return }
        considered.insert(sessionID)
        do {
            guard try runs.load(sessionID) == nil, try store.readSnapshot(sessionID: sessionID).isEmpty else { return }
            try runs.save(MinutesRun(sessionID: sessionID, state: "queued", sourceFingerprint: "", provider: settings.provider.rawValue, model: settings.connection.model))
        } catch { errors[sessionID] = error.localizedDescription; revision += 1; return }
        busySessionIDs.insert(sessionID)
        preparations[sessionID] = Task {
            defer { preparations.removeValue(forKey: sessionID); busySessionIDs.remove(sessionID); revision += 1 }
            do {
                try await captions.waitForSources(sessionID)
                try Task.checkCancellation()
                guard !preserving else { return }
                let current = try TextModelConfiguration().load()
                guard current.automatic, current.configured else { _ = cancel(sessionID); return }
                _ = try await generate(sessionID: sessionID)
            } catch is CancellationError { }
            catch {
                if var run = try? runs.load(sessionID), ["queued", "running"].contains(run.state) {
                    run.state = "failed"; run.message = error.localizedDescription; run.finishedAt = Date()
                    do { try runs.save(run) } catch { persistenceFailures.insert(sessionID) }
                }
                errors[sessionID] = error.localizedDescription; revision += 1
            }
        }
        revision += 1
    }
}
