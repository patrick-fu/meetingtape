import AVFoundation
import CryptoKit
import Darwin
import Foundation

public final class TranscriptionLock {
    private let descriptor: Int32
    public init(_ path: URL, wait: Bool = false) throws {
        descriptor = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TranscriptionFailure("无法打开转写锁。") }
        if flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            close(descriptor)
            throw TranscriptionFailure("转写任务正在运行。")
        }
    }
    deinit { close(descriptor) }
    var inheritedHandle: FileHandle { FileHandle(fileDescriptor: descriptor, closeOnDealloc: false) }
}

public struct TranscriptionStore: Sendable {
    public let root: URL
    public init(root: URL? = nil) throws {
        self.root = root ?? ProcessInfo.processInfo.environment["MEETINGTAPE_TRANSCRIPTION_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape/transcription")
        try Self.directory(self.root)
        try Self.directory(self.root.appendingPathComponent("tasks"))
    }
    public static func directory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TranscriptionFailure("转写目录必须由当前用户拥有且仅自己可访问。")
        }
    }
    public func taskDirectory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw TranscriptionFailure("无效转写任务 ID。") }
        return root.appendingPathComponent("tasks/" + id)
    }
    public func settings() throws -> TranscriptionSettings {
        let path = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return TranscriptionSettings() }
        let value: TranscriptionSettings = try read(path)
        guard value.schemaVersion == 1 else { throw TranscriptionFailure("转写设置版本不兼容。") }
        return value
    }
    public func saveSettings(_ value: TranscriptionSettings) throws {
        guard !value.models.isEmpty, Set(value.models).count == value.models.count,
              ["low-memory", "standard"].contains(value.profile) else { throw TranscriptionFailure("请选择模型与有效版本。") }
        let lock = try TranscriptionLock(root.appendingPathComponent("settings.lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        var current = try settings()
        current.models = value.models; current.automatic = value.automatic; current.profile = value.profile
        try write(current, to: root.appendingPathComponent("settings.json"))
    }
    public func activate(_ installation: LocalInstallation) throws {
        let lock = try TranscriptionLock(root.appendingPathComponent("settings.lock"), wait: true)
        defer { withExtendedLifetime(lock) {} }
        var current = try settings(); current.installations[installation.family] = installation
        try write(current, to: root.appendingPathComponent("settings.json"))
    }
    public func task(_ id: String) throws -> TranscriptionTask { try read(taskDirectory(id).appendingPathComponent("task.json")) }
    public func save(_ task: TranscriptionTask) throws { try write(task, to: taskDirectory(task.id).appendingPathComponent("task.json")) }
    public func tasks() throws -> [TranscriptionTask] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { try? read($0.appendingPathComponent("task.json")) as TranscriptionTask }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func result(_ task: String, model: TranscriptModel) throws -> TranscriptResult {
        try read(taskDirectory(task).appendingPathComponent(model.rawValue + ".json"))
    }
    public func write<T: Encodable>(_ value: T, to path: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func read<T: Decodable>(_ path: URL) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 32 * 1024 * 1024 else { throw TranscriptionFailure("转写数据过大。") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: path))
    }
    public static func fingerprint(_ path: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func recordingActive() -> Bool {
        let path = ProcessInfo.processInfo.environment["MEETINGTAPE_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent("session.lock").path) else { return false }
        if let lock = try? TranscriptionLock(path.appendingPathComponent("session.lock")) { withExtendedLifetime(lock) {}; return false }
        return true
    }
}
