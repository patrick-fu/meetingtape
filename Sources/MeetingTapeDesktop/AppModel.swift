import AppKit
import AVFoundation
import Combine
import MeetingTapeCore

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [RecordingItem] = []
    @Published var selectedID: String?
    @Published var query = ""
    @Published var filter = "all"
    @Published var snapshot: SessionSnapshot?
    @Published var operation: String?
    @Published var activeTitle = "新录音" {
        didSet {
            guard active, let sessionID = snapshot?.sessionID else { return }
            defaults.set(["sessionID": sessionID, "title": activeTitle], forKey: "activeRecordingTitle")
        }
    }
    @Published var panelExpanded = false
    @Published var panelPinned = UserDefaults.standard.object(forKey: "recordingPanelPinned") as? Bool ?? true {
        didSet { defaults.set(panelPinned, forKey: "recordingPanelPinned"); onChange?() }
    }
    @Published var errorMessage: String?
    @Published var savedMessage: String?
    @Published private(set) var libraryReadOnly = false
    @Published private(set) var retainedRecoveryPath: String?
    @Published var liveLevels = Array(repeating: 0.04, count: 36)
    @Published var waveform = Waveform()
    @Published var playing = false
    @Published var playbackSeconds = 0.0
    @Published var playbackDuration = 0.0
    @Published var outputDirectory: String
    @Published var keepRaw: Bool
    var onChange: (() -> Void)?
    var onOpenLibrary: (() -> Void)?
    var onShowRecordingPanel: (() -> Void)?
    private let client = RecordingClient()
    let transcription = TranscriptionModel()
    let liveCaptions = LiveCaptionModel()
    private let files = LibraryFiles()
    private let defaults = UserDefaults.standard
    private var saveTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var polling = false
    private var revision = 0

    init() {
        outputDirectory = UserDefaults.standard.string(forKey: "outputDirectory")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape").path
        keepRaw = UserDefaults.standard.bool(forKey: "keepRaw")
        retainedRecoveryPath = UserDefaults.standard.string(forKey: "retainedRecoveryPath")
    }

    var active: Bool {
        guard let state = snapshot?.state else { return false }
        return [.starting, .recording, .interrupted, .stopping, .finalizing].contains(state)
    }
    var panelVisible: Bool { active || operation != nil || snapshot?.state == .failed }
    var canStart: Bool { !active && operation == nil && snapshot?.state != .failed }
    var canStop: Bool { active && operation == nil && snapshot?.state != .finalizing && snapshot?.state != .stopping }
    var selected: RecordingItem? { records.first { $0.id == selectedID } }
    var visibleRecords: [RecordingItem] {
        records.filter { record in
            (filter != "starred" || record.starred) && (filter != "today" || Calendar.current.isDateInToday(record.date))
                && (query.isEmpty || record.title.localizedCaseInsensitiveContains(query))
        }.sorted { $0.date > $1.date }
    }
    var statusText: String {
        if let operation { return operation }
        switch snapshot?.state {
        case .interrupted: return "音源中断，正在重连"
        case .finalizing, .stopping: return "正在保存"
        case .failed: return "录音中断，已保留恢复材料"
        case .starting: return "正在准备录音"
        default: return active ? "正在录音" : "准备就绪"
        }
    }

    func launch() {
        transcription.launch()
        Task {
            do { records = try await files.load() }
            catch { libraryReadOnly = true; errorMessage = "无法读取资料库索引，原文件已保留。\n\(error.localizedDescription)" }
            await refreshLibrary()
            if selectedID == nil, let first = records.sorted(by: { $0.date > $1.date }).first { select(first.id) }
            await poll()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    await self.poll()
                }
            }
        }
    }

    func persist() {
        guard !libraryReadOnly else { return }
        let previous = saveTask
        let items = records
        saveTask = Task {
            await previous?.value
            do { try await files.save(items) }
            catch { libraryReadOnly = true; errorMessage = "资料库变更未保存：\(error.localizedDescription)"; onChange?() }
        }
    }

    func flush() async { await saveTask?.value; await liveCaptions.shutdown() }

    func refreshLibrary() async {
        var directories = defaults.stringArray(forKey: "recordingDirectories") ?? []
        directories.append(outputDirectory)
        do {
            let snapshots = try await files.discover(in: directories)
            for value in snapshots where !records.contains(where: { $0.id == value.outputPath }) {
                records.append(RecordingItem(snapshot: value, title: defaultTitle(for: value)))
            }
            if selectedID == nil, let first = records.sorted(by: { $0.date > $1.date }).first { select(first.id) }
            persist()
        } catch { errorMessage = "无法读取录音文件夹：\(error.localizedDescription)" }
    }

    private func poll() async {
        guard operation == nil, !polling else { return }
        polling = true
        let requestedRevision = revision
        defer { polling = false }
        do {
            var value = try await client.run(["status", "--json"])
            guard requestedRevision == revision, operation == nil else { return }
            if value?.state == .failed, value?.sessionID == defaults.string(forKey: "dismissedFailedSession") { value = nil }
            let previous = snapshot
            if let previous, previous.sessionID != value?.sessionID {
                await refreshLibrary()
                guard requestedRevision == revision, operation == nil else { return }
                liveCaptions.observe(records.first { $0.snapshot.sessionID == previous.sessionID }?.snapshot)
            }
            snapshot = value
            if value?.sessionID != previous?.sessionID, let value { activeTitle = defaultTitle(for: value) }
            if let value {
                liveCaptions.observe(value)
                rememberDirectory(URL(fileURLWithPath: value.recoveryPath).deletingLastPathComponent().path)
                if value.state == .completed { try acceptCompleted(value) }
                if value.state == .failed { panelExpanded = true }
            } else {
                liveCaptions.observe(nil)
            }
            if active {
                stopPlayback()
                let level = max(value?.systemLevel ?? 0, value?.microphoneLevel ?? 0)
                liveLevels.removeFirst(); liveLevels.append(meterHeight(level))
            }
            onChange?()
        } catch {
            guard requestedRevision == revision else { return }
            errorMessage = "无法读取录音状态：\(error.localizedDescription)"
            onChange?()
        }
    }

    func start() {
        guard canStart else { return }
        revision += 1; operation = "正在准备录音"; errorMessage = nil; savedMessage = nil
        stopPlayback(); panelExpanded = false; onChange?()
        let destination = outputDirectory
        let raw = keepRaw
        Task {
            do {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else { throw DesktopFailure(message: "请在系统设置的“隐私与安全性 → 麦克风”中允许 MeetingTape 使用麦克风。") }
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                let value = try await client.run(["start", "--out", destination, "--json"] + (raw ? ["--keep-raw"] : []))
                guard let value, value.state == .recording else { throw DesktopFailure(message: "录音尚未就绪。") }
                snapshot = value; activeTitle = defaultTitle(for: value)
                liveCaptions.observe(value, fromStart: true)
                rememberDirectory(destination)
            } catch { errorMessage = error.localizedDescription }
            operation = nil; onChange?()
            await poll()
        }
    }

    func stop() async -> Bool {
        guard canStop, let expected = snapshot?.sessionID else { return false }
        revision += 1; operation = "正在保存录音"; errorMessage = nil; onChange?()
        do {
            guard let value = try await client.run(["stop", "--session", expected, "--json"]) else { throw DesktopFailure(message: "未收到录音保存结果。") }
            liveCaptions.observe(value)
            try acceptCompleted(value)
            snapshot = nil; operation = nil; savedMessage = libraryReadOnly ? "录音文件已保存；资料库整理信息未保存" : "已保存到资料库"; onChange?()
            return true
        } catch {
            errorMessage = error.localizedDescription
            operation = nil; panelExpanded = true; onChange?()
            await poll()
            return false
        }
    }

    func recover() {
        guard operation == nil, snapshot?.state == .failed, let source = snapshot?.recoveryPath else { return }
        revision += 1; operation = "正在恢复录音"; errorMessage = nil; onChange?()
        Task {
            do {
                try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
                guard let value = try await client.run(["recover", source, "--out", outputDirectory, "--json"]) else {
                    throw DesktopFailure(message: "未收到恢复结果。")
                }
                try acceptCompleted(value); snapshot = nil; savedMessage = "录音已恢复到资料库"
            } catch { errorMessage = error.localizedDescription }
            operation = nil; onChange?()
        }
    }

    func keepFailedMaterials() {
        guard operation == nil, let value = snapshot, value.state == .failed else { return }
        defaults.set(value.sessionID, forKey: "dismissedFailedSession")
        retainedRecoveryPath = value.recoveryPath
        defaults.set(value.recoveryPath, forKey: "retainedRecoveryPath")
        snapshot = nil; errorMessage = nil; onChange?()
    }

    private func acceptCompleted(_ value: SessionSnapshot) throws {
        guard value.state == .completed, let path = value.outputPath,
              FileManager.default.isReadableFile(atPath: path),
              let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber, size.intValue > 0 else {
            throw DesktopFailure(message: "录音文件未完成，恢复材料仍保留在 \(value.recoveryPath)")
        }
        if !records.contains(where: { $0.id == path }) {
            let title = snapshot?.sessionID == value.sessionID ? activeTitle : defaultTitle(for: value)
            records.append(RecordingItem(snapshot: value, title: title))
            persist()
        }
        rememberDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        filter = "all"; query = ""; select(path)
    }

    private func rememberDirectory(_ path: String) {
        var directories = defaults.stringArray(forKey: "recordingDirectories") ?? []
        guard !directories.contains(path) else { return }
        directories.append(path); defaults.set(directories, forKey: "recordingDirectories")
    }

    private func defaultTitle(for value: SessionSnapshot) -> String {
        if let saved = defaults.dictionary(forKey: "activeRecordingTitle") as? [String: String],
           saved["sessionID"] == value.sessionID, let title = saved["title"] { return title }
        let date = ISO8601DateFormatter().date(from: value.startedAt) ?? Date()
        return "录音 " + date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        stopPlayback(); selectedID = id; waveform = Waveform()
        waveformTask?.cancel()
        guard let item = selected else { return }
        let url = item.url
        waveformTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try Waveform.read(url) }.value
                guard !Task.isCancelled, selectedID == id else { return }
                waveform = result
            } catch {
                guard !Task.isCancelled, selectedID == id else { return }
                errorMessage = "无法读取录音波形：\(error.localizedDescription)"
            }
        }
    }

    func rename(_ id: String, to title: String) {
        guard !libraryReadOnly else { return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名录音" : title
        persist()
    }

    func toggleStar(_ id: String) {
        guard !libraryReadOnly else { return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].starred.toggle(); persist()
    }

    func chooseDirectory() {
        guard !active, operation == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择"; panel.message = "新录音保存到此文件夹"
        panel.directoryURL = URL(fileURLWithPath: outputDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path; defaults.set(outputDirectory, forKey: "outputDirectory")
        rememberDirectory(outputDirectory)
        Task { await refreshLibrary() }
    }

    func setKeepRaw(_ value: Bool) { keepRaw = value; defaults.set(value, forKey: "keepRaw") }

    func togglePlayback() {
        if playing { player?.pause(); playing = false; return }
        guard let item = selected, item.exists, !active, operation == nil else { return }
        do {
            if player == nil { player = try AVAudioPlayer(contentsOf: item.url); playbackDuration = player?.duration ?? 0 }
            guard player?.play() == true else { throw DesktopFailure(message: "无法播放这段录音。") }
            playing = true
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.playbackSeconds = self.player?.currentTime ?? 0
                    self.playing = self.player?.isPlaying ?? false
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func seek(_ value: Double) {
        guard let player else { return }
        player.currentTime = value; playbackSeconds = value
    }

    func playSegment(_ value: Double) {
        guard !active, operation == nil else { return }
        if !playing { togglePlayback() }
        seek(value)
    }

    private func stopPlayback() {
        playbackTimer?.invalidate(); playbackTimer = nil
        player?.stop(); player = nil; playing = false; playbackSeconds = 0; playbackDuration = 0
    }

    func reveal(_ item: RecordingItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func revealRecovery() {
        guard let path = snapshot?.recoveryPath ?? retainedRecoveryPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
