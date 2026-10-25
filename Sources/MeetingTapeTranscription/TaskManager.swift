import Darwin
import Foundation
import MeetingTapeCore

public enum TranscriptionManager {
    public static func enqueue(input: String, models: [TranscriptModel]? = nil, sessionID: String? = nil,
                               automatic: Bool = false) throws -> TranscriptionTask {
        let store = try TranscriptionStore()
        let settings = try store.settings()
        let chosen = models ?? settings.models
        guard !chosen.isEmpty, Set(chosen).count == chosen.count else { throw TranscriptionFailure("至少选择一个转写模型。") }
        let path = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isReadableFile(atPath: path.path), !path.path.contains(".recovery/") else { throw TranscriptionFailure("请使用已保存的完整录音文件。") }
        let duration = try TranscriptionAudio.duration(path)
        let fingerprint = try TranscriptionStore.fingerprint(path)
        let lock = try TranscriptionLock(store.root.appendingPathComponent("enqueue.lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        if let previous = try store.tasks().first(where: { $0.inputPath == path.path && $0.inputSHA256 == fingerprint && (automatic || ($0.runs.map(\.model) == chosen && !$0.finished)) }) {
            if !previous.finished { launch(previous.id) }; return previous
        }
        for model in chosen where model.local {
            guard settings.installations[model.rawValue]?.available == true else { throw TranscriptionFailure("请先在设置中安装或配置 \(model.name)。") }
        }
        if chosen.contains(.doubao) { _ = try TranscriptionCredentials.load() }
        let task = TranscriptionTask(id: UUID().uuidString.lowercased(), inputPath: path.path, inputSHA256: fingerprint,
            sessionID: sessionID, duration: duration, createdAt: ISO8601DateFormatter().string(from: Date()), primaryModel: chosen[0],
            runs: chosen.map { model in TranscriptRun(model: model, installation: settings.installations[model.rawValue], revision: model.local ? settings.installations[model.rawValue]!.revision : "volc.seedasr.auc") })
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
                for index in task.runs.indices where task.runs[index].state != .succeeded && task.runs[index].state != .failed {
                    task.runs[index].state = .failed; task.runs[index].error = "转写进程已中断，可重试该模型。"
                }
                task.workerPID = nil; try store.save(task)
            }
        }
        return task
    }

    public static func retry(_ id: String, model: TranscriptModel) throws -> TranscriptionTask {
        let store = try TranscriptionStore()
        do {
            let lock = try TranscriptionLock(store.taskDirectory(id).appendingPathComponent("worker.lock"))
            defer { withExtendedLifetime(lock) {} }
            var task = try store.task(id)
            guard let index = task.runs.firstIndex(where: { $0.model == model && $0.state != .succeeded }) else { throw TranscriptionFailure("该模型没有需要重试的结果。") }
            task.runs[index].state = .queued; task.runs[index].error = nil; task.workerPID = nil
            task.lastLaunchAt = ISO8601DateFormatter().string(from: Date())
            if task.runs[index].cloudSubmission == "rejected" { task.runs[index].cloudRequestID = nil; task.runs[index].cloudSubmission = nil }
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

    public static func work(_ id: String) throws {
        let store = try TranscriptionStore()
        let directory = try store.taskDirectory(id)
        let lock = try TranscriptionLock(directory.appendingPathComponent("worker.lock"))
        defer { withExtendedLifetime(lock) {} }
        var task = try store.task(id)
        let fingerprint = try? TranscriptionStore.fingerprint(URL(fileURLWithPath: task.inputPath))
        guard fingerprint == task.inputSHA256 else {
            for index in task.runs.indices where task.runs[index].state != .succeeded {
                task.runs[index].state = .failed; task.runs[index].error = "录音文件已变化，不能继续原转写任务。"
            }
            task.workerPID = nil; try store.save(task); return
        }
        task.workerPID = getpid(); try store.save(task)
        for index in task.runs.indices where task.runs[index].state != .succeeded && task.runs[index].state != .failed {
            do {
                if task.runs[index].model.local { try local(&task, index: index, store: store) }
                else { try cloud(&task, index: index, store: store) }
                task.runs[index].state = .succeeded; task.runs[index].error = nil
            } catch { task.runs[index].state = .failed; task.runs[index].error = error.localizedDescription }
            try store.save(task)
        }
        task.workerPID = nil; try store.save(task)
    }

    private static func local(_ task: inout TranscriptionTask, index: Int, store: TranscriptionStore) throws {
        guard let installation = task.runs[index].installation, installation.available else { throw TranscriptionFailure("本地模型不可用，请检查安装。") }
        let directory = try store.taskDirectory(task.id)
        let family = task.runs[index].model
        let resultURL = directory.appendingPathComponent(family.rawValue + ".partial.json")
        var progress = (try? store.read(resultURL) as LocalProgress) ?? LocalProgress(result: TranscriptResult(model: family, revision: installation.revision, segments: []), completedChunks: 0)
        var result = progress.result
        task.runs[index].completedChunks = progress.completedChunks
        let chunks = Int(ceil(task.duration / 30))
        for chunk in task.runs[index].completedChunks..<chunks {
            var complete = false
            while !complete {
                task.runs[index].state = .waitingForRecording; try store.save(task)
                let executed: Bool? = try TranscriptionProcess.local { lease in
                    task.runs[index].state = .running; try store.save(task)
                    let start = Double(chunk) * 30, length = min(30, task.duration - start)
                    let audio = directory.appendingPathComponent("local-\(family.rawValue)-\(chunk).wav")
                    try TranscriptionAudio.prepare(URL(fileURLWithPath: task.inputPath), destination: audio, start: start, duration: length)
                    let raw = directory.appendingPathComponent("\(family.rawValue)-\(chunk).raw.json")
                    let output = try TranscriptionProcess.run(URL(fileURLWithPath: installation.python), [try TranscriptionResources.directory().appendingPathComponent("local_runner.py").path,
                        "--model-type", family.rawValue, "--model", installation.model, "--audio", audio.path, "--output", raw.path], environment: TranscriptionProcess.environment(offline: true), local: true, lease: lease)
                    if output.yielded { return false }
                    guard output.status == 0 else {
                        let detail = String(decoding: output.errors.suffix(1400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TranscriptionFailure("\(family.name) 转写失败：" + (detail.isEmpty ? "进程退出码 \(output.status)，请检查模型路径和访问权限。" : detail))
                    }
                    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: raw)) as? [String: Any] ?? [:]
                    let precision = payload["timestampPrecision"] as? String ?? "chunk"
                    var segments: [TranscriptSegment] = []
                    for value in payload["segments"] as? [[String: Any]] ?? [] {
                        guard let begin = value["start"] as? Double, let end = value["end"] as? Double, let text = value["text"] as? String,
                              begin.isFinite, end.isFinite, begin >= 0, end >= begin, begin <= length else { continue }
                        let speaker = (value["speaker"] as? String).map { "\(chunk + 1):\($0)" }
                        segments.append(TranscriptSegment(id: result.segments.count + segments.count, start: start + begin, end: min(start + end, start + length), text: text, speaker: speaker, precision: precision))
                    }
                    if segments.isEmpty, let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(TranscriptSegment(id: result.segments.count, start: start, end: start + length, text: text, precision: "chunk"))
                    }
                    result.segments.append(contentsOf: segments.sorted { $0.start < $1.start })
                    progress = LocalProgress(result: result, completedChunks: chunk + 1)
                    try store.write(progress, to: resultURL)
                    task.runs[index].completedChunks = chunk + 1; try store.save(task)
                    try? FileManager.default.removeItem(at: audio)
                    return true
                }
                complete = executed == true
                if !complete { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
        try store.write(result, to: directory.appendingPathComponent(family.rawValue + ".json"))
    }

    private static func cloud(_ task: inout TranscriptionTask, index: Int, store: TranscriptionStore) throws {
        let credential = try TranscriptionCredentials.load()
        let directory = try store.taskDirectory(task.id)
        task.runs[index].state = .running
        if task.runs[index].cloudRequestID == nil {
            task.runs[index].cloudRequestID = UUID().uuidString.lowercased()
            task.runs[index].cloudSubmission = "prepared"
        }
        try store.save(task)
        let requestID = task.runs[index].cloudRequestID!
        if task.runs[index].cloudSubmission == "prepared" {
            let audio = directory.appendingPathComponent("cloud.wav")
            try TranscriptionAudio.prepare(URL(fileURLWithPath: task.inputPath), destination: audio, start: 0, duration: task.duration)
            let payload = try Doubao.payload(audio)
            task.runs[index].cloudSubmission = "submitting"; try store.save(task)
            let submitted = try Doubao.request("submit", id: requestID, credential: credential, body: payload)
            task.runs[index].cloudLogID = submitted.logID
            guard submitted.code == "20000000" else {
                task.runs[index].cloudSubmission = "rejected"; try store.save(task)
                try store.write(["requestID": requestID, "code": submitted.code], to: directory.appendingPathComponent("doubao-rejected-\(requestID).json"))
                throw TranscriptionFailure("豆包提交失败（\(submitted.code)），可修正配置后重试。")
            }
            task.runs[index].cloudSubmission = "accepted"; try store.save(task)
            try? FileManager.default.removeItem(at: audio)
        }
        let deadline = Date().addingTimeInterval(4 * 3600)
        repeat {
            let response = try Doubao.request("query", id: requestID, credential: credential, body: [:])
            task.runs[index].cloudLogID = response.logID; try store.save(task)
            if task.runs[index].cloudSubmission == "submitting", !["20000000", "20000001", "20000002", "20000003"].contains(response.code) {
                throw TranscriptionFailure("豆包提交结果不确定，查询未取得结果（\(response.code)）。重试只查询原任务；需要再次上传时请重新转写。")
            }
            if ["20000001", "20000002"].contains(response.code) { Thread.sleep(forTimeInterval: 3); continue }
            let result = try Doubao.parse(response, duration: task.duration)
            try JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys]).write(to: directory.appendingPathComponent("doubao.raw.json"), options: .atomic)
            try store.write(result, to: directory.appendingPathComponent("doubao.json"))
            return
        } while Date() < deadline
        throw TranscriptionFailure("豆包任务仍未结束，可稍后重试查询；不会重新上传。")
    }
}

private struct LocalProgress: Codable {
    var result: TranscriptResult
    var completedChunks: Int
}
