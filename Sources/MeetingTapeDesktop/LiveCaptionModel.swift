import AppKit
import Combine
import MeetingTapeCore
import MeetingTapeTranscription

protocol LiveCaptionRunning: Actor {
    func finish(_ value: SessionSnapshot)
    func cancel()
    func run(update: @escaping @Sendable (LiveCaptionArchive) async -> Void) async -> LiveCaptionArchive
}

extension LiveCaptionSession: LiveCaptionRunning {}

@MainActor
final class LiveCaptionModel: ObservableObject {
    typealias SessionFactory = @MainActor (SessionSnapshot, Double, LiveCaptionStore) -> any LiveCaptionRunning
    @Published private(set) var enabled: Bool
    @Published private(set) var segments: [LiveCaptionSegment] = []
    @Published private(set) var message: String?
    @Published private(set) var connecting = false
    @Published private(set) var archiveRevision = 0
    let store: LiveCaptionStore
    private let makeSession: SessionFactory
    private struct Job {
        var sessionID: String
        var service: any LiveCaptionRunning
        var task: Task<Void, Never>
        var finishing = false
    }
    private var jobs: [Int: Job] = [:]
    private var current: Int?
    private var revision = 0
    private var snapshot: SessionSnapshot?

    init(enabled: Bool? = nil, store: LiveCaptionStore = LiveCaptionStore(), makeSession: @escaping SessionFactory = { LiveCaptionSession(snapshot: $0, startAt: $1, store: $2) }) {
        self.enabled = enabled ?? UserDefaults.standard.bool(forKey: "liveCaptionsEnabled")
        self.store = store; self.makeSession = makeSession
    }

    var sessionID: String? { snapshot?.sessionID }

    var currentLine: String {
        guard enabled else { return "实时字幕未开启" }
        if let last = segments.last { return last.text }
        if message != nil { return "字幕暂不可用" }
        return connecting ? "正在连接字幕…" : "正在聆听…"
    }
    var finalText: String { segments.filter(\.final).map(\.text).joined(separator: "\n") }
    var canRetry: Bool { enabled && active && current == nil && jobs.count < 4 }
    private var active: Bool { snapshot.map { [.starting, .recording, .interrupted].contains($0.state) } ?? false }

    func observe(_ value: SessionSnapshot?, fromStart: Bool = false) {
        guard let value else {
            snapshot = nil
            retireCurrent()
            return
        }
        let changed = snapshot?.sessionID != value.sessionID
        snapshot = value
        if [.completed, .failed].contains(value.state) {
            if let current, var job = jobs[current], job.sessionID == value.sessionID, !job.finishing {
                job.finishing = true; jobs[current] = job
                Task { await job.service.finish(value) }
            }
            return
        }
        if changed {
            retireCurrent(); segments = []; message = nil
            if enabled { start(at: fromStart ? 0 : value.committedSeconds) }
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value {
            let alert = NSAlert()
            alert.messageText = "开启豆包实时字幕？"
            alert.informativeText = "开启后，每次录音会将系统音频和麦克风声音实时发送至豆包，并使用你的账户计费。你可以随时在设置中关闭。"
            alert.addButton(withTitle: "开启"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        enabled = value; UserDefaults.standard.set(value, forKey: "liveCaptionsEnabled")
        if value, active, let snapshot { start(at: snapshot.committedSeconds) }
        else if !value {
            for job in jobs.values { job.task.cancel(); Task { await job.service.cancel() } }
            current = nil; connecting = false; message = nil
        }
    }

    func retry() {
        guard canRetry, let snapshot else { return }
        start(at: snapshot.committedSeconds)
    }

    func shutdown() async {
        let pending = Array(jobs.values)
        for job in pending where !job.finishing { job.task.cancel(); await job.service.cancel() }
        for job in pending { await job.task.value }
    }

    private func retireCurrent() {
        if let current, let job = jobs[current], !job.finishing {
            job.task.cancel(); Task { await job.service.cancel() }
        }
        current = nil; connecting = false
    }

    private func start(at offset: Double) {
        guard let snapshot else { return }
        retireCurrent()
        guard jobs.count < 4 else { message = "前几段字幕正在收尾，稍后可重连；录音继续。"; return }
        revision += 1
        let id = revision
        let barriers = jobs.values.filter { $0.sessionID == snapshot.sessionID }.map(\.task)
        let service = makeSession(snapshot, offset, store)
        current = id; connecting = true; message = nil
        let task = Task { [weak self] in
            for previous in barriers { await previous.value }
            if Task.isCancelled { self?.finished(id, document: nil); return }
            let document = await service.run { [weak self] value in await self?.accept(value, id: id) }
            self?.finished(id, document: document)
        }
        jobs[id] = Job(sessionID: snapshot.sessionID, service: service, task: task)
    }

    private func accept(_ value: LiveCaptionArchive, id: Int) {
        guard id == current else { return }
        segments = value.segments; message = value.message; connecting = false
    }

    private func finished(_ id: Int, document: LiveCaptionArchive?) {
        jobs.removeValue(forKey: id); archiveRevision += 1
        guard id == current else { return }
        if let document { accept(document, id: id) }
        current = nil; connecting = false
    }
}
