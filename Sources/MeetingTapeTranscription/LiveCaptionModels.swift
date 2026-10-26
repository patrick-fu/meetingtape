import Foundation

public struct LiveCaptionSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var final: Bool
}

public struct LiveCaptionArchive: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sessionID: String
    public var provider = "volc.seedasr.sauc.duration"
    public var segments: [LiveCaptionSegment] = []
    public var complete = false
    public var partial = false
    public var message: String?

    public init(sessionID: String) { self.sessionID = sessionID }
}

public actor LiveCaptionStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        self.directory = directory ?? library.appendingPathComponent("LiveCaptions")
    }

    public func load(_ sessionID: String) throws -> LiveCaptionArchive? {
        let path = try file(sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_048_576 else { throw TranscriptionFailure("实时字幕文件过大。") }
        let value = try JSONDecoder().decode(LiveCaptionArchive.self, from: Data(contentsOf: path))
        guard value.schemaVersion == 1, value.sessionID == sessionID, value.segments.count <= 20_000,
              value.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 172800 && $0.text.utf8.count <= 65536 }) else { throw TranscriptionFailure("实时字幕文件与录音不匹配或时间无效。") }
        return value
    }

    public func save(_ value: LiveCaptionArchive) throws {
        let path = try file(value.sessionID)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1_048_576 else { throw TranscriptionFailure("实时字幕已达到单次保存上限。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func file(_ sessionID: String) throws -> URL {
        guard let id = UUID(uuidString: sessionID) else { throw TranscriptionFailure("实时字幕的录音标识无效。") }
        return directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
}
