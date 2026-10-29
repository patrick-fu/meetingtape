import Foundation

public struct TranscriptExportVersion: Sendable, Identifiable {
    public let id: String
    public let title: String
    let task: TranscriptionTask?
    let run: TranscriptRun?
    let result: TranscriptResult?
    let live: LiveCaptionArchive?
    fileprivate let unreadableLive: Bool
    public var exportable: Bool { !unreadableLive && (result != nil || live != nil || run?.state != .succeeded) }

    public init(task: TranscriptionTask, run: TranscriptRun, result: TranscriptResult?) {
        id = task.id + ":" + run.model.rawValue
        title = "\(run.model.name) · 录后 · \(task.recognitionMode.name) · \(task.createdAt) · \(task.id.prefix(8))"
        self.task = task; self.run = run; self.result = result; live = nil
        unreadableLive = false
    }

    public init(live: LiveCaptionArchive, unreadable: Bool = false) {
        id = "live"; title = "豆包实时稿" + (unreadable ? "" : " · " + live.recognitionMode.name)
        self.live = unreadable ? nil : live; task = nil; run = nil; result = nil
        unreadableLive = unreadable
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
                versions.append(TranscriptExportVersion(task: task, run: run, result: try? store.result(task.id, model: run.model)))
            }
        }
        do {
            if let live = try captions.readSnapshot(sessionID) { versions.append(TranscriptExportVersion(live: live)) }
        } catch { versions.append(TranscriptExportVersion(live: LiveCaptionArchive(sessionID: sessionID), unreadable: true)) }
        guard !versions.isEmpty else { throw TranscriptionFailure("这段录音还没有转写版本。") }
        return Self(title: title, versions: versions, duration: tasks.first?.duration ?? versions.compactMap(\.live).first?.coverage.map(\.end).max())
    }

    public func markdown(primary: String, includeVersions: Bool = false) throws -> String {
        guard let selected = versions.first(where: { $0.id == primary }) else { throw TranscriptionFailure("主稿不存在，请从可用版本中明确选择。") }
        guard selected.exportable else { throw TranscriptionFailure("所选版本的正文缺失或不可读取。") }
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
        if version.unreadableLive { return ["状态：实时归档不可读取，原文件已保留。", ""] }
        var lines: [String] = []
        if let run = version.run {
            let unavailable = version.result?.unavailableSources ?? []
            let availability = version.result == nil && run.state == .succeeded ? "正文缺失或不可读取" : unavailable.isEmpty ? state(run.state) : "部分正文"
            lines += ["状态：\(availability)", ""]
            for source in run.sources { lines += ["- \(source.source.name)：\(state(source.state))\(unavailable.contains(source.source) ? "，正文缺失或不可读取" : "")"] }
            lines.append("")
            for segment in version.result?.segments ?? [] {
                let precision = segment.precision == "chunk" ? " · 音频块时间" : ""
                lines += ["**[\(time(segment.start, milliseconds: segment.precision != "chunk"))–\(time(segment.end, milliseconds: segment.precision != "chunk"))] \(segment.source.name)\(precision)**", "", text(segment.text), ""]
            }
            if let result = version.result {
                if result.segments.isEmpty { lines += [result.partial ? "未取得完整正文，已保存的结果将保留。" : "未识别到语音。", ""] }
            } else { lines += ["暂无可读取正文，执行记录已保留。", ""] }
        }
        if let live = version.live {
            lines += ["状态：\(live.complete ? "完成" : "部分字幕，含未覆盖或未定稿区间")", ""]
            for segment in live.segments {
                lines += ["**[\(time(segment.start))–\(time(segment.end))] \(segment.source.name)\(segment.final ? "" : " · 未定稿")**", ""]
                if !segment.text.isEmpty { lines += ["原文：" + text(segment.text), ""] }
                if let translation = segment.translation {
                    let language = text(SubtitleLanguage.name(translation.targetLanguage))
                    switch translation.state {
                    case .translated: lines += ["译文（\(language)）：" + text(translation.text ?? ""), ""]
                    case .sameLanguage:
                        if segment.text.isEmpty { lines += ["目标语言字幕（\(language)）：" + text(translation.text ?? ""), ""] }
                        lines += ["无需翻译。", ""]
                    case .pending: lines += ["译文（\(language)）：未取得定稿译文。", ""]
                    case .failed: lines += ["译文（\(language)）：翻译失败。", ""]
                    }
                }
            }
            if live.segments.isEmpty { lines += ["未取得字幕正文。", ""] }
            lines += ["### 实时功能覆盖", ""]
            if live.coverage.isEmpty { lines += ["历史未记录开关与连接区间，不能推断为全程开启。", ""] }
            else {
                lines += ["| 录音区间 [起点, 终点) | 音源 | 功能 | 状态 | 目标语言 |", "| --- | --- | --- | --- | --- |"]
                for interval in live.coverage.filter({ $0.end > $0.start }).sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
                    let feature = interval.feature == "transcription" ? "转写" : "字幕翻译"
                    let status = interval.state == "disabled" ? "该期间未开启" + feature : interval.state == "enabled" ? "已开启" : "历史未记录"
                    lines += ["| \(time(interval.start))–\(time(interval.end)) | \(interval.source.name) | \(feature) | \(status) | \(interval.targetLanguage.map { text(SubtitleLanguage.name($0)) } ?? "—") |"]
                }
                lines.append("")
            }
            for connection in live.connections {
                lines += ["- \(connection.source.name)连接：\(time(connection.start))–\(time(connection.end))，\(connection.state == "completed" ? "完成" : connection.state == "cancelled" ? "已停止" : connection.state == "failed" ? "识别连接失败" : "运行中")；仅描述该连接已处理区间，连接间空档不自动补录。"]
            }
            lines += ["", "以上只描述实时功能，不改变录音文件和其他录后版本的覆盖。", ""]
        }
        return lines
    }

    private static func statistics(_ version: TranscriptExportVersion) -> [String] {
        var lines = ["### " + text(version.title), ""]
        if version.unreadableLive { return lines + ["实时归档不可读取，统计不可得。", ""] }
        guard let run = version.run, let task = version.task else {
            if let live = version.live {
                for connection in live.connections {
                    lines += ["- 实时识别 · \(connection.source.name)：连接运行耗时 \(seconds(connection.elapsedSeconds))，包含等待新音频、网络与尾句收尾。"]
                }
                for segment in live.segments {
                    if let translation = segment.translation {
                        lines += ["- 字幕翻译 · \(segment.source.name) · \(time(segment.start)) · \(text(SubtitleLanguage.name(translation.targetLanguage))) · \(text(translation.provider))：耗时 \(seconds(translation.elapsedSeconds))。"]
                        if let usage = translation.usage, !usage.isEmpty {
                            lines += ["  服务返回用量：" + usage.keys.sorted().map { "\($0)=\(usage[$0]!) tokens" }.joined(separator: "，") + "。"]
                        }
                    }
                }
            }
            return lines + ["CPU、内存：未采集。云端资源不可得；未返回的计费用量不作估算。", ""]
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
