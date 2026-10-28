import Foundation

public struct TranscriptExportVersion: Sendable, Identifiable {
    public let id: String
    public let title: String
    let task: TranscriptionTask?
    let run: TranscriptRun?
    let result: TranscriptResult?
    let live: LiveCaptionArchive?

    public init(task: TranscriptionTask, run: TranscriptRun, result: TranscriptResult?) {
        id = task.id + ":" + run.model.rawValue
        title = "\(run.model.name) · 录后 · \(task.recognitionMode.name) · \(task.createdAt) · \(task.id.prefix(8))"
        self.task = task; self.run = run; self.result = result; live = nil
    }

    public init(live: LiveCaptionArchive) {
        id = "live"; title = "豆包实时稿 · 合并识别"
        self.live = live; task = nil; run = nil; result = nil
    }
}

public struct TranscriptExportSnapshot: Sendable {
    public var title: String
    public let versions: [TranscriptExportVersion]
    public let duration: Double?

    public init(title: String, versions: [TranscriptExportVersion], duration: Double? = nil) {
        self.title = title; self.versions = versions; self.duration = duration
    }

    public static func load(_ recording: String, title: String = "录音转写", store: TranscriptionStore? = nil, captions: LiveCaptionStore = LiveCaptionStore()) throws -> Self {
        let store = try store ?? TranscriptionStore()
        guard UUID(uuidString: recording) != nil else { throw TranscriptionFailure("请指定录音或转写任务 ID。") }
        let selected = FileManager.default.fileExists(atPath: try store.taskDirectory(recording).appendingPathComponent("task.json").path) ? try store.task(recording) : nil
        let all = try store.tasks()
        let sessionID = selected?.sessionID ?? recording
        let tasks = all.filter { task in
            if let selected { return task.id == selected.id || task.sessionID != nil && task.sessionID == selected.sessionID || task.inputPath == selected.inputPath && task.inputSHA256 == selected.inputSHA256 }
            return task.sessionID == sessionID
        }
        var versions: [TranscriptExportVersion] = []
        for task in tasks {
            for run in task.runs {
                let result: TranscriptResult?
                let directory = try store.taskDirectory(task.id)
                let hasResult = run.sources.contains { source in
                    let prefix = TranscriptionStore.resultPrefix(run.model, source: source.source)
                    return [".json", ".partial.json"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent(prefix + $0).path) }
                }
                if run.state == .succeeded, !hasResult { throw TranscriptionFailure("已完成的转写缺少正文文件，不能导出为空稿。") }
                result = hasResult ? try store.result(task.id, model: run.model) : nil
                versions.append(TranscriptExportVersion(task: task, run: run, result: result))
            }
        }
        if let live = try captions.readSnapshot(sessionID) { versions.append(TranscriptExportVersion(live: live)) }
        guard !versions.isEmpty else { throw TranscriptionFailure("这段录音还没有转写版本。") }
        return Self(title: title, versions: versions, duration: tasks.first?.duration)
    }

    public func markdown(primary: String, includeVersions: Bool = false) throws -> String {
        guard let selected = versions.first(where: { $0.id == primary }) else { throw TranscriptionFailure("主稿不存在，请从可用版本中明确选择。") }
        let included = [selected] + (includeVersions ? versions.filter { $0.id != primary } : [])
        var lines = ["# " + Self.text(title), "", "- 主稿：" + Self.text(selected.title)]
        if let duration { lines.append("- 录音时长：" + Self.time(duration)) }
        lines += ["", "## 主稿", ""] + Self.body(selected)
        for version in included.dropFirst() {
            lines += ["", "<details>", "<summary>其他版本：\(Self.text(version.title))</summary>", ""] + Self.body(version) + ["", "</details>"]
        }
        lines += ["", "<details>", "<summary>运行统计</summary>", ""]
        for version in included { lines += Self.statistics(version) }
        lines += ["", "</details>", ""]
        return lines.joined(separator: "\n")
    }

    private static func body(_ version: TranscriptExportVersion) -> [String] {
        var lines: [String] = []
        if let run = version.run {
            lines += ["状态：\(state(run.state))", ""]
            for source in run.sources { lines += ["- \(source.source.name)：\(state(source.state))"] }
            lines.append("")
            for segment in version.result?.segments ?? [] {
                let precision = segment.precision == "chunk" ? " · 音频块时间" : ""
                lines += ["**[\(time(segment.start, milliseconds: segment.precision != "chunk"))–\(time(segment.end, milliseconds: segment.precision != "chunk"))] \(segment.source.name)\(precision)**", "", text(segment.text), ""]
            }
            if version.result?.segments.isEmpty != false { lines += [run.state == .succeeded ? "未识别到语音。" : "未取得完整正文，已保存的结果将保留。", ""] }
        }
        if let live = version.live {
            lines += ["状态：\(live.complete ? "完成" : "部分字幕，含未覆盖或未定稿区间")", "", "覆盖：历史未记录开关与连接区间，不能推断为全程开启。", ""]
            for segment in live.segments {
                lines += ["**[\(time(segment.start))–\(time(segment.end))] 合并音源\(segment.final ? "" : " · 未定稿")**", "", text(segment.text), ""]
            }
            if live.segments.isEmpty { lines += ["未取得字幕正文。", ""] }
        }
        return lines
    }

    private static func statistics(_ version: TranscriptExportVersion) -> [String] {
        var lines = ["### " + text(version.title), ""]
        guard let run = version.run, let task = version.task else {
            return lines + ["运行耗时、CPU、内存：未采集。云端资源与用量：不可得，服务未提供。", ""]
        }
        lines += ["| 音源 / 尝试 | 状态 | 已处理音频 | 排队耗时 | 执行耗时 | 总耗时 | CPU 累计时间 | 峰值 RSS |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for source in run.sources {
            if source.attempts.isEmpty {
                let audio = source.state == .succeeded ? "0–\(time(task.duration))" : "未采集"
                lines.append("| \(source.source.name) | \(state(source.state)) | \(audio) | 未采集 | 未采集 | 未采集 | 未采集 | 未采集 |")
            }
            for (index, attempt) in source.attempts.enumerated() {
                let dates = ISO8601DateFormatter()
                let queue = dates.date(from: attempt.queuedAt).flatMap { queued in dates.date(from: attempt.startedAt).map { max(0, $0.timeIntervalSince(queued)) } }
                let audio = attempt.completedAudioSeconds.map { "0–\(time($0))（累计进度）" } ?? "未采集"
                let cpu = run.model.local ? seconds(attempt.cpuSeconds) : "不可得：服务未提供"
                let memory = run.model.local ? attempt.peakResidentBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "未采集" : "不可得：服务未提供"
                lines.append("| \(source.source.name) / \(index + 1) | \(state(attempt.state)) | \(audio) | \(seconds(queue)) | \(seconds(attempt.executionSeconds)) | \(seconds(attempt.elapsedSeconds)) | \(cpu) | \(memory) |")
            }
            for (index, attempt) in source.attempts.enumerated() where attempt.resourceScope != nil {
                lines += ["", "\(source.source.name)第 \(index + 1) 次尝试：CPU 为 \(attempt.observedChunks) 个已观测 runner 进程的累计时间；RSS 为这些单独进程的峰值最大值，不包含 GPU、其他进程或整机内存。"]
            }
        }
        lines += ["", run.model.local ? "执行耗时包含音频准备与实际推理；总耗时还包含等待录音优先锁的时间。" : "执行与总耗时包含上传、网络等待和轮询；云端 CPU、内存和计费用量不可得，服务未提供。", ""]
        return lines
    }

    private static func state(_ value: TranscriptRunState) -> String {
        switch value {
        case .queued: "排队中"
        case .waitingForRecording: "录音优先，等待中"
        case .running: "转写中"
        case .succeeded: "成功"
        case .failed: "失败"
        case .partial: "部分完成"
        }
    }

    private static func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "未采集" }

    private static func time(_ value: Double, milliseconds: Bool = true) -> String {
        guard value.isFinite, value >= 0 else { return "时间未知" }
        let count = Int64((value * 1000).rounded())
        let base = String(format: "%02lld:%02lld:%02lld", count / 3_600_000, count / 60_000 % 60, count / 1000 % 60)
        return milliseconds ? base + String(format: ".%03lld", count % 1000) : base
    }

    private static func text(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\\", "`", "*", "_", "[", "]", "{", "}", "#", "|", "!", "~", "-", "+", ".": result += "\\" + String(character)
            case "\n": result += "<br>"
            case "\r": break
            default: if !character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { result.append(character) }
            }
        }
        return result
    }
}
