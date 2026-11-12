import Darwin
import Foundation

public enum LiveRecognitionProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case doubao, senseVoice
    public var id: Self { self }
    public var name: String { self == .doubao ? "豆包实时语音 2.0" : "SenseVoice 本地字幕" }
}

public struct LocalLiveInstallation: Codable, Sendable {
    public let schemaVersion: Int
    public let python: String
    public let model: String
    public let tokens: String
    public let vad: String
    public let revision: String
    public let runtimeVersion: String
    public let ready: Bool
}

public struct LocalLiveStatus: Codable, Sendable {
    public var state: String
    public var phase: String?
    public var message: String?
    public var installation: LocalLiveInstallation?
}

public struct LocalLiveRuntime: Sendable {
    public let root: URL
    public init(root: URL? = nil) throws {
        self.root = try root ?? ProcessInfo.processInfo.environment["MEETINGTAPE_LIVE_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
            ?? TranscriptionStore().root.appendingPathComponent("local-live")
    }

    public func status() throws -> LocalLiveStatus {
        let file = root.appendingPathComponent("status.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalLiveStatus(state: "notInstalled") }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw TranscriptionFailure("本地字幕安装记录无效。") }
        var value = try JSONDecoder().decode(LocalLiveStatus.self, from: Data(contentsOf: file))
        if value.state == "installing", let lock = try? TranscriptionLock(root.appendingPathComponent("bootstrap.lock")) {
            withExtendedLifetime(lock) {}
            value.state = "failed"; value.message = "安装已中断，可以重新安装。"
        }
        return value
    }

    public func installation() throws -> LocalLiveInstallation {
        let file = root.appendingPathComponent("installation.json")
        guard FileManager.default.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw TranscriptionFailure("请先在模型设置中安装本地字幕模型。") }
        let value = try JSONDecoder().decode(LocalLiveInstallation.self, from: Data(contentsOf: file))
        guard value.ready, value.schemaVersion == 1, value.revision == "355f4d4884d8afd08aef04b9007a8556d7b463b2", value.runtimeVersion == "sherpa-onnx-2.0.1",
              [value.python, value.model, value.tokens, value.vad].allSatisfy({ $0.hasPrefix("/") && FileManager.default.isReadableFile(atPath: $0) }),
              FileManager.default.isExecutableFile(atPath: value.python) else { throw TranscriptionFailure("本地字幕模型未就绪，请在设置中重新验证。") }
        return value
    }

    public func install() throws -> LocalLiveStatus {
        let script = try TranscriptionResources.directory().appendingPathComponent("live_bootstrap.py")
        let output = try TranscriptionProcess.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", "-B", script.path, "--root", root.path], environment: TranscriptionProcess.environment(offline: false), timeout: 1800)
        guard output.status == 0 else { throw TranscriptionFailure((try? status().message) ?? "本地字幕安装未完成，请重试。") }
        _ = try installation()
        return try status()
    }
}

struct LocalLiveEvent: Decodable, Sendable {
    struct Statistics: Decodable, Sendable {
        let scope: String
        let cpuSeconds: Double
        let peakResidentBytes: Int64
        let decodeElapsedSeconds: Double
        let decodedAudioSeconds: Double
    }
    let type: String
    let segments: [LiveCaptionSegment]?
    let statistics: Statistics?
    let message: String?
}

final class LocalLiveProcess: @unchecked Sendable {
    let events: AsyncThrowingStream<LocalLiveEvent, any Error>
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private var stopped = false

    init(installation: LocalLiveInstallation, startAt: Double) throws {
        let process = Process(), standardInput = Pipe(), output = Pipe(), errors = Pipe()
        self.process = process; input = standardInput.fileHandleForWriting
        process.executableURL = URL(fileURLWithPath: installation.python)
        process.arguments = ["-I", "-B", try TranscriptionResources.directory().appendingPathComponent("local_live_runner.py").path,
                             "--model", installation.model, "--tokens", installation.tokens, "--vad", installation.vad, "--start-at", String(startAt)]
        process.environment = TranscriptionProcess.environment(offline: true)
        process.standardInput = standardInput; process.standardOutput = output; process.standardError = errors
        var continuation: AsyncThrowingStream<LocalLiveEvent, any Error>.Continuation!
        events = AsyncThrowingStream { continuation = $0 }
        do { try process.run() }
        catch { try? input.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); throw error }
        try? standardInput.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let stream = continuation!
        DispatchQueue.global().async {
            while !errors.fileHandleForReading.availableData.isEmpty {}
            try? errors.fileHandleForReading.close()
        }
        DispatchQueue.global().async {
            do {
                var buffer = Data(), finished = false
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    guard buffer.count <= 8 * 1_048_576 else { throw TranscriptionFailure("本地字幕响应过大。") }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        guard !line.isEmpty else { continue }
                        let event = try JSONDecoder().decode(LocalLiveEvent.self, from: line)
                        guard ["ready", "caption", "finished", "error"].contains(event.type), !finished else { throw TranscriptionFailure("本地字幕响应顺序无效。") }
                        if event.type == "error" { throw TranscriptionFailure(event.message ?? "本地字幕识别失败。") }
                        if event.type == "finished" { finished = true }
                        stream.yield(event)
                    }
                }
                process.waitUntilExit()
                guard buffer.isEmpty, finished, process.terminationStatus == 0 else { throw TranscriptionFailure("本地字幕进程未正常收尾，已保留现有文字。") }
                stream.finish()
            } catch { stream.finish(throwing: error) }
            try? output.fileHandleForReading.close()
        }
    }

    func send(_ pcm: Data) async throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 128000 else { throw TranscriptionFailure("本地字幕音频块无效。") }
        try await write(["audio": pcm.base64EncodedString()])
    }

    func finish() async throws { try await write(["finish": true]); try input.close() }

    func stop() {
        lock.lock(); let needsStop = !stopped; stopped = true; lock.unlock()
        guard needsStop else { return }
        if process.isRunning { process.terminate() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func write(_ value: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        let bytes = data, input = input
        try await Task.detached { try input.write(contentsOf: bytes) }.value
    }

    deinit { stop(); try? input.close() }
}
