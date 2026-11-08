import Foundation

public struct LiveCaptionSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var final: Bool
    public var source: TranscriptSource = .merged
    public var connectionID: String?
    public var revision = 0
    public var translation: CaptionTranslation?

    public var targetText: String? {
        guard let translation else { return nil }
        return translation.state == .sameLanguage && !text.isEmpty ? text : translation.text
    }
    public var plainText: String {
        [text.isEmpty ? nil : text, translation?.state != .sameLanguage || text.isEmpty ? translation?.text : nil].compactMap { $0 }.joined(separator: "\n")
    }
}

public struct LiveCaptionArchive: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sessionID: String
    public var provider = "volc.seedasr.sauc.duration"
    public var segments: [LiveCaptionSegment] = []
    public var complete = false
    public var partial = false
    public var message: String?
    public var recognitionMode: RecognitionMode = .merged
    public var coverage: [CaptionCoverage] = []
    public var connections: [CaptionConnection] = []
    public var updateRevision = 0
    public var translationJobs: [CaptionTranslationJob] = []
    public var translationVersions: [CaptionTranslationVersion] = []
    public var translationSealedRuns: [String] = []

    public init(sessionID: String) { self.sessionID = sessionID }
}

extension LiveCaptionSegment {
    private enum CodingKeys: String, CodingKey { case id, start, end, text, final, source, connectionID, revision, translation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text); final = try c.decode(Bool.self, forKey: .final)
        source = try c.decodeIfPresent(TranscriptSource.self, forKey: .source) ?? .merged
        connectionID = try c.decodeIfPresent(String.self, forKey: .connectionID)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        translation = try c.decodeIfPresent(CaptionTranslation.self, forKey: .translation)
    }
}

extension LiveCaptionArchive {
    private enum CodingKeys: String, CodingKey { case schemaVersion, sessionID, provider, segments, complete, partial, message, recognitionMode, coverage, connections, updateRevision, translationJobs, translationVersions, translationSealedRuns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sessionID = try c.decode(String.self, forKey: .sessionID); provider = try c.decode(String.self, forKey: .provider)
        segments = try c.decode([LiveCaptionSegment].self, forKey: .segments)
        complete = try c.decode(Bool.self, forKey: .complete); partial = try c.decode(Bool.self, forKey: .partial)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        recognitionMode = try c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode) ?? .merged
        coverage = try c.decodeIfPresent([CaptionCoverage].self, forKey: .coverage) ?? []
        connections = try c.decodeIfPresent([CaptionConnection].self, forKey: .connections) ?? []
        updateRevision = try c.decodeIfPresent(Int.self, forKey: .updateRevision) ?? 0
        translationJobs = try c.decodeIfPresent([CaptionTranslationJob].self, forKey: .translationJobs) ?? []
        translationVersions = try c.decodeIfPresent([CaptionTranslationVersion].self, forKey: .translationVersions) ?? []
        translationSealedRuns = try c.decodeIfPresent([String].self, forKey: .translationSealedRuns) ?? []
    }
}

public actor LiveCaptionStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        let library = ProcessInfo.processInfo.environment["MEETINGTAPE_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingTape")
        self.directory = directory ?? library.appendingPathComponent("LiveCaptions")
    }

    public func load(_ sessionID: String) throws -> LiveCaptionArchive? { try readSnapshot(sessionID) }

    public nonisolated func readSnapshot(_ sessionID: String) throws -> LiveCaptionArchive? {
        let path = try file(sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_048_576 else { throw TranscriptionFailure("实时字幕文件过大。") }
        let value = try JSONDecoder().decode(LiveCaptionArchive.self, from: Data(contentsOf: path))
        guard UUID(uuidString: value.sessionID) == UUID(uuidString: sessionID) else { throw TranscriptionFailure("实时字幕文件与录音不匹配。") }
        try Self.validate(value)
        return value
    }

    public func save(_ value: LiveCaptionArchive) throws {
        try Self.validate(value)
        let path = try file(value.sessionID)
        guard value.segments.count <= 20_000, value.translationJobs.count <= 60_000, value.translationVersions.count <= 100 else { throw TranscriptionFailure("实时字幕已达到单次文本上限，已有归档已保留。") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1_048_576 else { throw TranscriptionFailure("实时字幕已达到单次保存上限。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    public func recordControls(_ sessionID: String, at time: Double, mode: RecognitionMode, options: SubtitleOptions, newObserver: Bool = false) throws {
        guard time.isFinite, time >= 0, time <= 172800 else { throw TranscriptionFailure("字幕覆盖时间无效。") }
        var value = try load(sessionID) ?? LiveCaptionArchive(sessionID: sessionID)
        value.schemaVersion = max(2, value.schemaVersion); value.recognitionMode = mode
        for source in mode.sources {
            for feature in ["transcription", "translation"] {
                let enabled = feature == "transcription" ? options.transcription : options.translation
                let state = enabled ? "enabled" : "disabled"
                let target = feature == "translation" ? options.targetLanguage : nil
                if let last = value.coverage.lastIndex(where: { $0.source == source && $0.feature == feature }) {
                    guard time >= value.coverage[last].end else { continue }
                    if newObserver, time > value.coverage[last].end {
                        value.coverage.append(CaptionCoverage(id: UUID().uuidString.lowercased(), start: value.coverage[last].end, end: time, source: source, feature: feature, state: "unknown", targetLanguage: nil))
                        value.coverage.append(CaptionCoverage(id: UUID().uuidString.lowercased(), start: time, end: time, source: source, feature: feature, state: state, targetLanguage: target))
                        continue
                    }
                    value.coverage[last].end = time
                    if value.coverage[last].state == state && value.coverage[last].targetLanguage == target { continue }
                } else if time > 0 {
                    value.coverage.append(CaptionCoverage(id: UUID().uuidString.lowercased(), start: 0, end: time, source: source, feature: feature, state: "unknown", targetLanguage: nil))
                }
                value.coverage.append(CaptionCoverage(id: UUID().uuidString.lowercased(), start: time, end: time, source: source, feature: feature, state: state, targetLanguage: target))
            }
        }
        value.updateRevision += 1
        value.partial = value.partial || value.coverage.contains { ($0.state == "disabled" || $0.state == "unknown") && $0.end > $0.start }
        if value.partial { value.complete = false }
        try save(value)
    }

    func updateConnection(_ sessionID: String, mode: RecognitionMode, connection: CaptionConnection, segments: [LiveCaptionSegment], translationInputs: [LiveCaptionSegment] = [], options: SubtitleOptions? = nil, runID: String = "") throws -> LiveCaptionArchive {
        var value = try load(sessionID) ?? LiveCaptionArchive(sessionID: sessionID)
        if let sealed = value.connections.first(where: { $0.id == connection.id }), ["completed", "cancelled", "failed"].contains(sealed.state), !["completed", "cancelled", "failed"].contains(connection.state) { return value }
        if value.translationSealedRuns.contains(runID) { return value }
        value.schemaVersion = max(2, value.schemaVersion); value.recognitionMode = mode
        let saved = Dictionary(uniqueKeysWithValues: value.segments.map { ($0.id, $0) })
        value.segments.removeAll { $0.connectionID == connection.id }
        value.segments.append(contentsOf: segments.map { segment in
            var segment = segment
            if let old = saved[segment.id], old.translation?.targetLanguage == segment.translation?.targetLanguage {
                segment.translation?.text = old.translation?.text
            }
            return segment
        })
        value.segments.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        if let index = value.connections.firstIndex(where: { $0.id == connection.id }) { value.connections[index] = connection }
        else { value.connections.append(connection) }
        if let options, options.translation {
            value.schemaVersion = 3
            value.enqueueTranslations(translationInputs, options: options, runID: runID)
        }
        value.projectTranslations(); value.refreshCompletion()
        value.updateRevision += 1
        try save(value)
        return value
    }

    private nonisolated static func validate(_ value: LiveCaptionArchive) throws {
        guard [1, 2, 3].contains(value.schemaVersion), UUID(uuidString: value.sessionID) != nil, value.segments.count <= 20_000,
              Set(value.segments.map(\.id)).count == value.segments.count,
              value.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 172800 && $0.text.utf8.count <= 65536 && ($0.translation?.text?.utf8.count ?? 0) <= 65536 }),
              value.coverage.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 172800 }),
              value.translationJobs.count <= 60_000, value.translationVersions.count <= 100, value.translationSealedRuns.count <= 1000,
              Set(value.translationJobs.map(\.id)).count == value.translationJobs.count,
              Set(value.translationVersions.map(\.id)).count == value.translationVersions.count,
              value.translationJobs.allSatisfy({ job in job.input.utf8.count <= 65536 && job.attempts.count <= 3 && (job.versionID.map { id in value.translationVersions.contains { $0.id == id } } ?? true) }) else { throw TranscriptionFailure("实时字幕文件与录音不匹配或时间无效。") }
        for version in value.translationVersions {
            guard UUID(uuidString: version.id) != nil, version.segments.count <= 20_000,
                  Set(version.segments.map(\.id)).count == version.segments.count,
                  version.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 172800 && $0.text.utf8.count <= 65536 && ($0.translation?.text?.utf8.count ?? 0) <= 65536 }) else { throw TranscriptionFailure("字幕版本无效，已有归档已保留。") }
        }
    }

    private nonisolated func file(_ sessionID: String) throws -> URL {
        guard let id = UUID(uuidString: sessionID) else { throw TranscriptionFailure("实时字幕的录音标识无效。") }
        return directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
}
