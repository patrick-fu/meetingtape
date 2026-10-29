import Darwin
import Foundation

public enum TranscriptionResources {
    public static func directory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETINGTAPE_TRANSCRIPTION_RESOURCES"] { return URL(fileURLWithPath: override) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Transcription"),
                          executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Transcription"),
                          executable.deletingLastPathComponent().appendingPathComponent("Transcription")]
        guard let result = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("local_runner.py").path) }) else {
            throw TranscriptionFailure("缺少转写运行资源，请重新构建 App。")
        }
        return result
    }
}

public struct RecordingPriorityPermit {
    private let intent: TranscriptionLock
    private let inference: TranscriptionLock
    public init() throws {
        let store = try TranscriptionStore()
        intent = try TranscriptionLock(store.root.appendingPathComponent("recording-intent.lock"))
        let deadline = Date().addingTimeInterval(10)
        var acquired: TranscriptionLock?
        repeat {
            acquired = try? TranscriptionLock(store.root.appendingPathComponent("inference.lock"))
            if acquired != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        guard let acquired else { throw TranscriptionFailure("本地模型未及时释放资源，请稍后再开始录音。") }
        inference = acquired
    }
    public func retain() { withExtendedLifetime((intent, inference)) {} }
}

enum TranscriptionProcess {
    struct Output { var data: Data; var errors: Data; var status: Int32; var yielded: Bool }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    local: Bool = false, lease: TranscriptionLock? = nil, timeout: TimeInterval = 600) throws -> Output {
        let process = Process()
        defer { withExtendedLifetime(process) {} }
        let output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        var childEnvironment = environment
        if local { childEnvironment = childEnvironment ?? Self.environment(offline: true); childEnvironment?["MEETINGTAPE_OWNER_PID"] = String(getpid()) }
        process.environment = childEnvironment
        process.standardInput = lease?.inheritedHandle ?? FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); throw error }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let readers = DispatchGroup()
        let data = ProcessBytes(), diagnostics = ProcessBytes()
        readers.enter(); DispatchQueue.global().async { data.set(output.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter(); DispatchQueue.global().async { diagnostics.set(errors.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        var yielded = false
        let deadline = Date().addingTimeInterval(timeout)
        while exited.wait(timeout: .now() + 0.1) != .success {
            let requested = local && (TranscriptionStore.recordingActive() || recordingRequested())
            if requested || Date() > deadline {
                yielded = requested
                process.terminate()
                if exited.wait(timeout: .now() + 2) != .success { kill(process.processIdentifier, SIGKILL); exited.wait() }
                break
            }
        }
        readers.wait()
        return Output(data: data.value, errors: diagnostics.value, status: process.terminationStatus, yielded: yielded)
    }

    static func recordingRequested() -> Bool {
        guard let store = try? TranscriptionStore() else { return true }
        if let lock = try? TranscriptionLock(store.root.appendingPathComponent("recording-intent.lock")) { withExtendedLifetime(lock) {}; return false }
        return true
    }

    static func environment(offline: Bool) -> [String: String] {
        let process = ProcessInfo.processInfo.environment
        var result = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                      "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "TOKENIZERS_PARALLELISM": "false"]
        if let user = process["USER"] { result["USER"] = user }
        if offline { result["HF_HUB_OFFLINE"] = "1"; result["TRANSFORMERS_OFFLINE"] = "1" }
        return result
    }

    static func local<T>(_ action: (TranscriptionLock) throws -> T) throws -> T? {
        let store = try TranscriptionStore()
        guard let lock = try? TranscriptionLock(store.root.appendingPathComponent("inference.lock")) else { return nil }
        defer { withExtendedLifetime(lock) {} }
        guard !TranscriptionStore.recordingActive(), !recordingRequested() else { return nil }
        return try action(lock)
    }
}

private final class ProcessBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
