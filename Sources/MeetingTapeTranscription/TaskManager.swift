import Darwin
import Foundation
import MeetingTapeCore

public enum TranscriptionManager {
    public static func enqueue(input: String, models: [TranscriptModel]? = nil, sessionID: String? = nil,
                               automatic: Bool = false, mode: RecognitionMode? = nil) throws -> TranscriptionTask {
        let store = try TranscriptionStore()
        let settings = try store.settings()
        let chosen = models ?? settings.models
        guard !chosen.isEmpty, Set(chosen).count == chosen.count else { throw TranscriptionFailure("至少选择一个转写模型。") }
        let path = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isReadableFile(atPath: path.path), !path.path.contains(".recovery/") else { throw TranscriptionFailure("请使用已保存的完整录音文件。") }
        let information = try TranscriptionAudio.inspect(path)
        let recognitionMode = mode ?? (information.nativeSessionID == nil ? .merged : settings.recognitionMode)
        guard recognitionMode != .separate || information.nativeSessionID != nil else {
            throw TranscriptionFailure("无法确认此文件的系统/麦克风映射，请使用合并识别。")
        }
        if let sessionID, let native = information.nativeSessionID, sessionID != native {
            throw TranscriptionFailure("录音标识与文件元数据不匹配。")
        }
        let fingerprint = try TranscriptionStore.fingerprint(path)
        let lock = try TranscriptionLock(store.root.appendingPathComponent("enqueue.lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        if let previous = try store.tasks().first(where: { $0.inputPath == path.path && $0.inputSHA256 == fingerprint && (automatic || ($0.runs.map(\.model) == chosen && $0.recognitionMode == recognitionMode && !$0.finished)) }) {
            if !previous.finished { launch(previous.id) }; return previous
        }
        for model in chosen where model.local {
            guard settings.installations[model.rawValue]?.available == true else { throw TranscriptionFailure("请先在设置中安装或配置 \(model.name)。") }
        }
        if chosen.contains(.doubao) { _ = try TranscriptionCredentials.load() }
        var task = TranscriptionTask(id: UUID().uuidString.lowercased(), inputPath: path.path, inputSHA256: fingerprint,
            sessionID: sessionID ?? information.nativeSessionID, duration: information.duration, createdAt: ISO8601DateFormatter().string(from: Date()), primaryModel: chosen[0],
            runs: chosen.map { model in TranscriptRun(model: model, installation: settings.installations[model.rawValue], revision: model.local ? settings.installations[model.rawValue]!.revision : "volc.seedasr.auc", sources: recognitionMode.sources) })
        task.schemaVersion = 2; task.recognitionMode = recognitionMode
        task.nativeSourceMapping = information.nativeSessionID != nil
        for index in task.runs.indices { for source in task.runs[index].sources.indices { task.runs[index].sources[source].queuedAt = task.createdAt } }
        try TranscriptionStore.directory(store.taskDirectory(task.id))
        try store.save(task)
        launch(task.id)
        return task
    }

    public static func automatic(_ snapshot: SessionSnapshot) {
        guard snapshot.state == .completed, let output = snapshot.outputPath else { return }
        do {
            let store = try TranscriptionStore()
            let settings = try store.settings()
            guard settings.automatic, let executable = Bundle.main.executableURL else { return }
            let process = Process(); process.executableURL = executable
            process.arguments = ["__automatic", output, snapshot.sessionID, settings.models.map(\.rawValue).joined(separator: ",")]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            if let store = try? TranscriptionStore() { try? store.write(["message": error.localizedDescription, "sessionID": snapshot.sessionID], to: store.root.appendingPathComponent("automatic-error.json")) }
        }
    }

    public static func automaticWork(input: String, sessionID: String, models: [TranscriptModel]) {
        do {
            _ = try enqueue(input: input, models: models, sessionID: sessionID, automatic: true)
            if let store = try? TranscriptionStore() { try? FileManager.default.removeItem(at: store.root.appendingPathComponent("automatic-error.json")) }
        } catch {
            if let store = try? TranscriptionStore() { try? store.write(["message": error.localizedDescription, "sessionID": sessionID], to: store.root.appendingPathComponent("automatic-error.json")) }
        }
    }

    public static func status(_ id: String) throws -> TranscriptionTask {
        let store = try TranscriptionStore()
        var task = try store.task(id)
        if let lock = try? TranscriptionLock(store.taskDirectory(id).appendingPathComponent("worker.lock")) {
            defer { withExtendedLifetime(lock) {} }
            task = try store.task(id)
            let age = ISO8601DateFormatter().date(from: task.lastLaunchAt ?? task.createdAt).map { Date().timeIntervalSince($0) } ?? 0
            if task.workerPID != nil || task.runs.contains(where: { $0.state == .running || $0.state == .waitingForRecording }) || (!task.finished && age > 10) {
                for index in task.runs.indices { for source in task.runs[index].sources.indices where !task.runs[index].sources[source].state.finished {
                    task.runs[index].sources[source].state = .failed
                    task.runs[index].sources[source].error = "转写进程已中断，可重试该音源。"
                    if let attempt = task.runs[index].sources[source].attempts.indices.last,
                       !task.runs[index].sources[source].attempts[attempt].state.finished {
                        task.runs[index].sources[source].attempts[attempt].state = .failed
                        task.runs[index].sources[source].attempts[attempt].finishedAt = ISO8601DateFormatter().string(from: Date())
                        task.runs[index].sources[source].attempts[attempt].error = "转写进程已中断。"
                    }
                }
                }
                task.workerPID = nil; try store.save(task)
            }
        }
        return task
    }

    public static func retry(_ id: String, model: TranscriptModel, source: TranscriptSource? = nil) throws -> TranscriptionTask {
        let store = try TranscriptionStore()
        do {
            let lock = try TranscriptionLock(store.taskDirectory(id).appendingPathComponent("worker.lock"))
            defer { withExtendedLifetime(lock) {} }
            var task = try store.task(id)
            guard let index = task.runs.firstIndex(where: { $0.model == model && $0.state != .succeeded }) else { throw TranscriptionFailure("该模型没有需要重试的结果。") }
            let selected = task.runs[index].sources.indices.filter { task.runs[index].sources[$0].state != .succeeded && (source == nil || task.runs[index].sources[$0].source == source) }
            guard !selected.isEmpty else { throw TranscriptionFailure("该音源没有需要重试的结果。") }
            for lane in selected {
                task.runs[index].sources[lane].state = .queued; task.runs[index].sources[lane].error = nil
                task.runs[index].sources[lane].queuedAt = ISO8601DateFormatter().string(from: Date())
                if task.runs[index].sources[lane].cloudSubmission == "rejected" {
                    task.runs[index].sources[lane].cloudRequestID = nil; task.runs[index].sources[lane].cloudSubmission = nil
                }
            }
            task.workerPID = nil
            task.lastLaunchAt = ISO8601DateFormatter().string(from: Date())
            try store.save(task)
        }
        launch(id)
        return try store.task(id)
    }

    public static func launch(_ id: String) {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process(); process.executableURL = executable
        process.arguments = ["__transcribe", id]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    public static func work(_ id: String, store: TranscriptionStore? = nil, runner: URL? = nil) throws {
        let store = try store ?? TranscriptionStore()
        let directory = try store.taskDirectory(id)
        let lock = try TranscriptionLock(directory.appendingPathComponent("worker.lock"))
        defer { withExtendedLifetime(lock) {} }
        var task = try store.task(id)
        let fingerprint = try? TranscriptionStore.fingerprint(URL(fileURLWithPath: task.inputPath))
        guard fingerprint == task.inputSHA256 else {
            for index in task.runs.indices { for source in task.runs[index].sources.indices where task.runs[index].sources[source].state != .succeeded {
                task.runs[index].sources[source].state = .failed
                task.runs[index].sources[source].error = "录音文件已变化，不能继续原转写任务。"
            }
            }
            task.workerPID = nil; try store.save(task); return
        }
        task.workerPID = getpid(); try store.save(task)
        for index in task.runs.indices { for lane in task.runs[index].sources.indices where !task.runs[index].sources[lane].state.finished {
            var source = task.runs[index].sources[lane]
            let began = ProcessInfo.processInfo.systemUptime
            source.attempts.append(TranscriptAttempt(queuedAt: source.queuedAt ?? task.createdAt, startedAt: ISO8601DateFormatter().string(from: Date()), state: .running))
            task.runs[index].sources[lane] = source; try store.save(task)
            let context = task, run = task.runs[index]
            do {
                if run.model.local {
                    source.state = try local(context, run: run, source: &source, store: store, runner: runner) { progress in
                        task.runs[index].sources[lane] = progress; try store.save(task)
                    }
                    if source.state == .succeeded { source.error = nil }
                } else {
                    try cloud(context, run: run, source: &source, store: store) { progress in
                        task.runs[index].sources[lane] = progress; try store.save(task)
                    }
                    source.state = .succeeded; source.error = nil
                }
            } catch { source.state = .failed; source.error = error.localizedDescription }
            if let attempt = source.attempts.indices.last {
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - began)
                source.attempts[attempt].elapsedSeconds = elapsed
                if !run.model.local { source.attempts[attempt].executionSeconds = elapsed }
                source.attempts[attempt].finishedAt = ISO8601DateFormatter().string(from: Date())
                source.attempts[attempt].state = source.state; source.attempts[attempt].error = source.error
                if source.state == .succeeded { source.attempts[attempt].completedAudioSeconds = task.duration }
            }
            task.runs[index].sources[lane] = source
            try store.save(task)
        }
        }
        task.workerPID = nil; try store.save(task)
    }

    private static func local(_ task: TranscriptionTask, run: TranscriptRun, source: inout TranscriptSourceExecution,
                              store: TranscriptionStore, runner: URL? = nil, save: (TranscriptSourceExecution) throws -> Void) throws -> TranscriptRunState {
        guard let installation = run.installation, installation.available else { throw TranscriptionFailure("本地模型不可用，请检查安装。") }
        let directory = try store.taskDirectory(task.id)
        let family = run.model
        let prefix = TranscriptionStore.resultPrefix(family, source: source.source)
        let resultURL = try store.resultPath(task.id, model: family, source: source.source, partial: true)
        var progress: LocalProgress
        if FileManager.default.fileExists(atPath: resultURL.path) { progress = try store.read(resultURL) }
        else { progress = LocalProgress(result: TranscriptResult(model: family, revision: installation.revision, segments: []), completedChunks: 0) }
        var result = progress.result
        let chunks = Int(ceil(task.duration / 30))
        guard progress.completedChunks >= 0, progress.completedChunks <= chunks, result.model == family else {
            throw TranscriptionFailure("已有转写进度无效，原文件已保留。")
        }
        var skipped = Set(progress.skippedChunks.filter { $0 >= 0 && $0 < progress.completedChunks })
        let pendingChunks = Array(progress.completedChunks..<chunks) + skipped.sorted()
        source.completedChunks = max(0, progress.completedChunks - skipped.count)
        let attempt = source.attempts.count - 1
        source.attempts[attempt].completedAudioSeconds = completedAudioSeconds(scanned: progress.completedChunks, skipped: skipped, duration: task.duration)
        for chunk in pendingChunks {
            var complete = false
            while !complete {
                let outcome: LocalExecution<Bool> = try TranscriptionProcess.local(store: store) { lease in
                    let began = ProcessInfo.processInfo.systemUptime
                    defer { source.attempts[attempt].executionSeconds += max(0, ProcessInfo.processInfo.systemUptime - began) }
                    if source.state != .running { source.state = .running; try save(source) }
                    let start = Double(chunk) * 30, length = min(30, task.duration - start)
                    let audio = directory.appendingPathComponent("local-\(prefix)-\(chunk).wav")
                    defer { try? FileManager.default.removeItem(at: audio) }
                    try TranscriptionAudio.prepare(URL(fileURLWithPath: task.inputPath), destination: audio, start: start, duration: length, source: source.source)
                    let raw = directory.appendingPathComponent("\(prefix)-\(chunk)-\(UUID().uuidString.lowercased()).raw.json")
                    let runnerPath = try runner?.path ?? TranscriptionResources.directory().appendingPathComponent("local_runner.py").path
                    let output = try TranscriptionProcess.run(URL(fileURLWithPath: installation.python), [runnerPath,
                        "--model-type", family.rawValue, "--model", installation.model, "--audio", audio.path, "--output", raw.path],
                        environment: TranscriptionProcess.environment(offline: true), local: true, lease: lease, store: store)
                    if output.yielded { return false }
                    let payload = (try? JSONSerialization.jsonObject(with: Data(contentsOf: raw))) as? [String: Any]
                    if let statistics = payload?["statistics"] as? [String: Any],
                       statistics["scope"] as? String == "runner-process",
                       let cpu = statistics["cpuSeconds"] as? Double, cpu.isFinite, cpu >= 0,
                       let memory = statistics["peakResidentBytes"] as? UInt64 {
                        source.attempts[attempt].cpuSeconds = (source.attempts[attempt].cpuSeconds ?? 0) + cpu
                        source.attempts[attempt].peakResidentBytes = max(source.attempts[attempt].peakResidentBytes ?? 0, memory)
                        source.attempts[attempt].observedChunks += 1
                        source.attempts[attempt].resourceScope = "runner-processes"
                    }
                    guard output.status == 0 else {
                        if payload?["errorCode"] as? String == "decoder_exhausted" {
                            skipped.insert(chunk)
                            let scanned = max(progress.completedChunks, chunk + 1)
                            let sortedSkipped = skipped.sorted()
                            progress = LocalProgress(result: result, completedChunks: scanned, skippedChunks: sortedSkipped)
                            try store.write(progress, to: resultURL)
                            source.completedChunks = max(0, scanned - sortedSkipped.count)
                            source.attempts[attempt].completedAudioSeconds = completedAudioSeconds(scanned: scanned, skipped: skipped, duration: task.duration)
                            source.error = skippedSummary(family: family, skipped: sortedSkipped, completed: source.completedChunks, totalChunks: chunks, duration: task.duration, finished: false)
                            try save(source)
                            return true
                        }
                        let detail = String(decoding: output.errors.suffix(1400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TranscriptionFailure("\(family.name) 转写失败：" + (detail.isEmpty ? "进程退出码 \(output.status)，请检查模型路径和访问权限。" : detail))
                    }
                    guard let payload, payload["text"] is String, payload["segments"] is [[String: Any]] else {
                        throw TranscriptionFailure("\(family.name) 未返回有效正文，此音频块未记为完成。")
                    }
                    let precision = payload["timestampPrecision"] as? String ?? "chunk"
                    var nextIndex = source.source.nextSegmentIndex(after: result.segments)
                    var segments: [TranscriptSegment] = []
                    for value in payload["segments"] as? [[String: Any]] ?? [] {
                        guard let begin = value["start"] as? Double, let end = value["end"] as? Double, let text = value["text"] as? String,
                              begin.isFinite, end.isFinite, begin >= 0, end >= begin, begin <= length else { continue }
                        let speaker = (value["speaker"] as? String).map { "\(chunk + 1):\($0)" }
                        segments.append(TranscriptSegment(id: source.source.segmentID(nextIndex),
                            start: start + begin, end: min(start + end, start + length), text: text, speaker: speaker,
                            precision: precision, source: source.source))
                        nextIndex += 1
                    }
                    if segments.isEmpty, let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(TranscriptSegment(id: source.source.segmentID(nextIndex), start: start, end: start + length, text: text, precision: "chunk", source: source.source))
                    }
                    result.segments.append(contentsOf: segments)
                    result.segments.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
                    skipped.remove(chunk)
                    let scanned = max(progress.completedChunks, chunk + 1)
                    let sortedSkipped = skipped.sorted()
                    progress = LocalProgress(result: result, completedChunks: scanned, skippedChunks: sortedSkipped)
                    try store.write(progress, to: resultURL)
                    source.completedChunks = max(0, scanned - sortedSkipped.count)
                    source.attempts[attempt].completedAudioSeconds = completedAudioSeconds(scanned: scanned, skipped: skipped, duration: task.duration)
                    source.error = sortedSkipped.isEmpty ? nil : skippedSummary(family: family, skipped: sortedSkipped, completed: source.completedChunks, totalChunks: chunks, duration: task.duration, finished: false)
                    try save(source)
                    return true
                }
                switch outcome {
                case .executed(true):
                    complete = true
                case .executed(false), .waitingForRecording:
                    if source.state != .waitingForRecording { source.state = .waitingForRecording; try save(source) }
                    Thread.sleep(forTimeInterval: 0.5)
                case .waitingForInference:
                    if source.state != .queued { source.state = .queued; try save(source) }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        let sortedSkipped = skipped.sorted()
        if sortedSkipped.isEmpty {
            try store.write(result, to: store.resultPath(task.id, model: family, source: source.source))
            source.error = nil
            return .succeeded
        }
        source.error = skippedSummary(family: family, skipped: sortedSkipped, completed: source.completedChunks, totalChunks: chunks, duration: task.duration, finished: true)
        return sortedSkipped.count < chunks ? .partial : .failed
    }

    static func completedAudioSeconds(scanned: Int, skipped: Set<Int>, duration: Double) -> Double {
        guard scanned > 0 else { return 0 }
        var total = 0.0
        for chunk in 0..<scanned where !skipped.contains(chunk) {
            total += min(30.0, max(0.0, duration - Double(chunk) * 30.0))
        }
        return min(duration, total)
    }

    static func skippedSummary(family: TranscriptModel, skipped: [Int], completed: Int, totalChunks: Int, duration: Double, finished: Bool) -> String {
        if finished && skipped.count >= totalChunks {
            return "\(family.name) 全部 \(totalChunks) 个音频块均达到生成上限，未生成正文，请回听或改用其他模型。"
        }
        var ranges: [(Int, Int)] = []
        for chunk in skipped.sorted() {
            if let last = ranges.last, chunk == last.1 + 1 { ranges[ranges.count - 1].1 = chunk }
            else { ranges.append((chunk, chunk)) }
        }
        func format(_ seconds: Double, roundUp: Bool = false) -> String {
            let total = max(0, Int(roundUp ? seconds.rounded(.up) : seconds.rounded(.down)))
            let hours = total / 3600, minutes = (total / 60) % 60, secs = total % 60
            return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
        }
        let listed = ranges.prefix(5).map { "\(format(Double($0.0) * 30))–\(format(min(duration, Double($0.1 + 1) * 30), roundUp: true))" }.joined(separator: "、")
        let suffix = ranges.count > 5 ? " 等" : ""
        let progressText = finished ? "其余 \(completed)/\(totalChunks) 块已完成" : "当前已完成 \(completed)/\(totalChunks) 块"
        return "\(skipped.count) 个音频块达到生成上限已跳过（\(listed)\(suffix)），\(progressText)，请回听跳过区间或改用其他模型。"
    }

    private static func cloud(_ task: TranscriptionTask, run: TranscriptRun, source: inout TranscriptSourceExecution,
                              store: TranscriptionStore, save: (TranscriptSourceExecution) throws -> Void) throws {
        let credential = try TranscriptionCredentials.load()
        let directory = try store.taskDirectory(task.id)
        let prefix = TranscriptionStore.resultPrefix(run.model, source: source.source)
        source.state = .running
        if source.cloudRequestID == nil {
            source.cloudRequestID = UUID().uuidString.lowercased()
            source.cloudSubmission = "prepared"
        }
        try save(source)
        let requestID = source.cloudRequestID!
        if source.cloudSubmission == "prepared" {
            let audio = directory.appendingPathComponent("\(prefix)-cloud.wav")
            defer { try? FileManager.default.removeItem(at: audio) }
            try TranscriptionAudio.prepare(URL(fileURLWithPath: task.inputPath), destination: audio, start: 0, duration: task.duration, source: source.source)
            let payload = try Doubao.payload(audio)
            source.cloudSubmission = "submitting"; try save(source)
            let submitted = try Doubao.request("submit", id: requestID, credential: credential, body: payload)
            source.cloudLogID = submitted.logID
            guard submitted.code == "20000000" else {
                source.cloudSubmission = "rejected"; try save(source)
                try store.write(["requestID": requestID, "code": submitted.code], to: directory.appendingPathComponent("doubao-rejected-\(requestID).json"))
                throw TranscriptionFailure("豆包提交失败（\(submitted.code)），可修正配置后重试。")
            }
            source.cloudSubmission = "accepted"; try save(source)
        }
        let deadline = Date().addingTimeInterval(4 * 3600)
        repeat {
            let response = try Doubao.request("query", id: requestID, credential: credential, body: [:])
            source.cloudLogID = response.logID; try save(source)
            if source.cloudSubmission == "submitting", !["20000000", "20000001", "20000002", "20000003"].contains(response.code) {
                throw TranscriptionFailure("豆包提交结果不确定，查询未取得结果（\(response.code)）。重试只查询原任务；需要再次上传时请重新转写。")
            }
            if ["20000001", "20000002"].contains(response.code) { Thread.sleep(forTimeInterval: 3); continue }
            var result = try Doubao.parse(response, duration: task.duration)
            for index in result.segments.indices {
                result.segments[index].source = source.source
                result.segments[index].id = source.source.segmentID(index)
            }
            try JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys]).write(to: directory.appendingPathComponent("\(prefix).raw.json"), options: .atomic)
            try store.write(result, to: store.resultPath(task.id, model: run.model, source: source.source))
            return
        } while Date() < deadline
        throw TranscriptionFailure("豆包任务仍未结束，可稍后重试查询；不会重新上传。")
    }
}

struct LocalProgress: Codable {
    var result: TranscriptResult
    var completedChunks: Int
    var skippedChunks: [Int] = []

    private enum CodingKeys: String, CodingKey { case result, completedChunks, skippedChunks }
    init(result: TranscriptResult, completedChunks: Int, skippedChunks: [Int] = []) {
        self.result = result; self.completedChunks = completedChunks; self.skippedChunks = skippedChunks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(TranscriptResult.self, forKey: .result)
        completedChunks = try c.decode(Int.self, forKey: .completedChunks)
        skippedChunks = try c.decodeIfPresent([Int].self, forKey: .skippedChunks) ?? []
    }
}
