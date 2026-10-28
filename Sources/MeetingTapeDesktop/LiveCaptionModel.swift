import AppKit
import Combine
import MeetingTapeCore
import MeetingTapeTranscription

protocol LiveCaptionRunning: Actor {
    func finish(_ value: SessionSnapshot) async
    func cancel() async
    func retryFailed(at time: Double) async -> Bool
    func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive
}

extension LiveCaptionSession: LiveCaptionRunning {}
extension LiveCaptionRunning { func retryFailed(at time: Double) async -> Bool { false } }

@MainActor
final class LiveCaptionModel: ObservableObject {
    typealias SessionFactory = @MainActor (SessionSnapshot, Double, LiveCaptionStore) -> any LiveCaptionRunning
    @Published private(set) var enabled: Bool
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var targetLanguage: String
    @Published private(set) var provider: SubtitleTranslationProvider
    @Published private(set) var segments: [LiveCaptionSegment] = []
    @Published private(set) var message: String?
    @Published private(set) var connecting = false
    @Published private(set) var archiveRevision = 0
    let store: LiveCaptionStore
    var onResize: (() -> Void)?
    private let makeSession: SessionFactory?
    private struct Job {
        var sessionID: String
        var service: (any LiveCaptionRunning)?
        var task: Task<Void, Never>
        var finishing = false
    }
    private var jobs: [Int: Job] = [:]
    private var current: Int?
    private var revision = 0
    private var acceptedRevision = 0
    private var snapshot: SessionSnapshot?
    private var observedAt = ProcessInfo.processInfo.systemUptime
    private var coverageAt = -1.0
    private var controls: Task<Void, Never>?
    private var failedSource = false
    @Published private var retrying: Int?

    init(enabled: Bool? = nil, store: LiveCaptionStore = LiveCaptionStore(), makeSession: SessionFactory? = nil) {
        self.enabled = enabled ?? UserDefaults.standard.bool(forKey: "liveCaptionsEnabled")
        translationEnabled = enabled == nil && UserDefaults.standard.bool(forKey: "liveTranslationEnabled")
        targetLanguage = UserDefaults.standard.string(forKey: "liveTargetLanguage") ?? "zh-Hans"
        provider = SubtitleTranslationProvider(rawValue: UserDefaults.standard.string(forKey: "liveTranslationProvider") ?? "local") ?? .local
        self.store = store; self.makeSession = makeSession
    }

    var sessionID: String? { snapshot?.sessionID }
    var anyEnabled: Bool { enabled || translationEnabled }
    var latest: LiveCaptionSegment? { segments.last }
    var compactHeight: CGFloat { !anyEnabled ? 39 : enabled && translationEnabled ? (latest.map { $0.text.count + ($0.targetText?.count ?? 0) > 75 } == true ? 120 : 106) : 73 }
    var currentLine: String {
        guard anyEnabled else { return "" }
        if let last = segments.last {
            if enabled, !last.text.isEmpty { return last.text }
            if let text = last.targetText { return text }
        }
        if message != nil { return "字幕暂不可用" }
        return connecting ? "正在连接字幕…" : "正在聆听…"
    }
    var translationLine: String {
        guard translationEnabled else { return "" }
        guard let value = latest?.translation else { return "等待翻译…" }
        switch value.state {
        case .pending: return "正在翻译…"
        case .failed: return "翻译暂不可用"
        case .sameLanguage: return enabled ? "无需翻译" : value.text ?? "无需翻译"
        case .translated: return value.text ?? ""
        }
    }
    var finalText: String {
        segments.filter(\.final).map(\.plainText).joined(separator: "\n")
    }
    var canRetry: Bool { anyEnabled && active && retrying == nil && (current == nil || failedSource) && jobs.count < 4 }
    private var active: Bool { snapshot.map { [.starting, .recording, .interrupted].contains($0.state) } ?? false }
    private var options: SubtitleOptions {
        var value = SubtitleOptions()
        value.transcription = enabled; value.translation = translationEnabled
        value.targetLanguage = targetLanguage; value.provider = provider
        return value
    }
    private var now: Double {
        guard let snapshot else { return 0 }
        return snapshot.elapsedSeconds + (active ? max(0, ProcessInfo.processInfo.systemUptime - observedAt) : 0)
    }

    func observe(_ value: SessionSnapshot?, fromStart: Bool = false) {
        guard let value else { snapshot = nil; retireCurrent(); return }
        let changed = snapshot?.sessionID != value.sessionID
        snapshot = value; observedAt = ProcessInfo.processInfo.systemUptime
        if changed {
            retireCurrent(); segments = []; message = nil; acceptedRevision = 0; coverageAt = -1
        }
        if changed || floor(value.elapsedSeconds) > floor(coverageAt) || [.completed, .failed].contains(value.state) {
            recordControls(at: fromStart && changed ? 0 : value.elapsedSeconds, newObserver: changed && !fromStart)
        }
        if [.completed, .failed].contains(value.state) {
            if let current, var job = jobs[current], job.sessionID == value.sessionID, !job.finishing {
                job.finishing = true; jobs[current] = job
                if let service = job.service { Task { await service.finish(value) } }
            }
            return
        }
        if changed, anyEnabled { start(at: fromStart ? 0 : now) }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value, !anyEnabled, !confirmCloudASR() { return }
        enabled = value; UserDefaults.standard.set(value, forKey: "liveCaptionsEnabled")
        reconfigure()
    }

    func setTranslationEnabled(_ value: Bool) {
        guard value != translationEnabled else { return }
        if value, !anyEnabled, !confirmCloudASR() { return }
        translationEnabled = value; UserDefaults.standard.set(value, forKey: "liveTranslationEnabled")
        reconfigure()
    }

    func setTargetLanguage(_ value: String) {
        guard value != targetLanguage, SubtitleLanguage.identifiers.contains(value) else { return }
        targetLanguage = value; UserDefaults.standard.set(value, forKey: "liveTargetLanguage")
        reconfigure()
    }

    func setProvider(_ value: SubtitleTranslationProvider) {
        guard value != provider else { return }
        provider = value; UserDefaults.standard.set(value.rawValue, forKey: "liveTranslationProvider")
        reconfigure()
    }

    private func confirmCloudASR() -> Bool {
        let alert = NSAlert()
        alert.messageText = "开启实时语音识别？"
        alert.informativeText = "实时字幕和字幕翻译均需将声音发送至豆包语音识别，使用你的账户计费。选择本地翻译时，文字翻译在设备上完成。"
        alert.addButton(withTitle: "开启"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reconfigure() {
        if snapshot != nil { recordControls(at: now) }
        if anyEnabled, active { start(at: now) }
        else { retireCurrent(); message = nil }
        onResize?()
    }

    func retry() {
        guard canRetry else { return }
        if let current, let service = jobs[current]?.service {
            let time = now
            retrying = current
            Task { [weak self] in
                let resumed = await service.retryFailed(at: time)
                guard let self, self.current == current, self.active, self.anyEnabled else { return }
                self.retrying = nil
                if resumed { self.failedSource = false }
                else { self.start(at: self.now) }
            }
        } else { start(at: now) }
    }

    func shutdown() async {
        let pending = Array(jobs.values)
        for job in pending where !job.finishing { job.task.cancel(); if let service = job.service { await service.cancel() } }
        for job in pending { await job.task.value }
        await controls?.value
    }

    private func recordControls(at offset: Double, newObserver: Bool = false) {
        guard let snapshot else { return }
        let previous = controls, store = self.store, options = self.options
        let mode = snapshot.recognitionMode ?? .merged
        coverageAt = offset
        controls = Task { [weak self] in
            await previous?.value
            do { try await store.recordControls(snapshot.sessionID, at: offset, mode: mode, options: options, newObserver: newObserver) }
            catch { self?.message = "字幕覆盖记录未保存：\(error.localizedDescription)" }
        }
    }

    private func retireCurrent() {
        if let current, let job = jobs[current], !job.finishing {
            job.task.cancel(); if let service = job.service { Task { await service.cancel() } }
        }
        current = nil; connecting = false; retrying = nil
    }

    private func start(at offset: Double) {
        guard let starting = snapshot else { return }
        retireCurrent()
        guard jobs.count < 4 else { message = "前几段字幕正在收尾，稍后可重连；录音继续。"; return }
        revision += 1
        let id = revision
        let barriers = jobs.values.filter { $0.sessionID == starting.sessionID }.map(\.task)
        let controls = self.controls
        current = id; connecting = true; message = nil
        failedSource = false
        let task = Task { [weak self] in
            for previous in barriers { await previous.value }
            await controls?.value
            guard let self else { return }
            guard !Task.isCancelled, let value = self.snapshot, value.sessionID == starting.sessionID else { self.finished(id, document: nil); return }
            let begin = offset == 0 && barriers.isEmpty ? 0 : max(offset, self.now)
            let service = self.makeSession?(value, begin, self.store) ?? LiveCaptionSession(snapshot: value, startAt: begin, store: self.store, options: self.options)
            self.jobs[id]?.service = service
            if [.completed, .failed].contains(value.state) { await service.finish(value) }
            let document = await service.run { [weak self] value in await self?.accept(value, id: id) }
            self.finished(id, document: document)
        }
        jobs[id] = Job(sessionID: starting.sessionID, task: task)
    }

    private func accept(_ value: LiveCaptionArchive, id: Int) {
        guard id == current, value.updateRevision >= acceptedRevision else { return }
        let height = compactHeight
        acceptedRevision = value.updateRevision
        let sources = (snapshot?.recognitionMode ?? .merged).sources
        failedSource = sources.contains { source in value.connections.last(where: { $0.source == source })?.state == "failed" }
        segments = value.segments; message = value.message; connecting = false
        if compactHeight != height { onResize?() }
    }

    private func finished(_ id: Int, document: LiveCaptionArchive?) {
        jobs.removeValue(forKey: id); archiveRevision += 1
        guard id == current else { return }
        if let document { accept(document, id: id) }
        current = nil; connecting = false; retrying = nil
    }
}
