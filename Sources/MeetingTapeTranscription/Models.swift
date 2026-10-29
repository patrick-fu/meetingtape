import Foundation

public enum TranscriptModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case qwen, moss, doubao
    public var id: String { rawValue }
    public var name: String { switch self { case .qwen: "Qwen3 ASR"; case .moss: "MOSS"; case .doubao: "豆包 2.0" } }
    public var local: Bool { self != .doubao }
}

public struct LocalInstallation: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var family: String
    public var profile: String
    public var python: String
    public var model: String
    public var revision: String
    public var repository: String
    public var runtimeVersion: String
    public var ready: Bool?
    public var available: Bool { ready == true && FileManager.default.isExecutableFile(atPath: python) && FileManager.default.fileExists(atPath: model + "/config.json") }
}

public struct TranscriptionSettings: Codable, Sendable {
    public var schemaVersion = 1
    public var models: [TranscriptModel] = [.qwen]
    public var automatic = false
    public var installations: [String: LocalInstallation] = [:]
    public var profile = "low-memory"
    public var recognitionMode: RecognitionMode = .separate
    public init() {}
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var precision: String
    public var source: TranscriptSource = .merged
    public init(id: Int, start: Double, end: Double, text: String, speaker: String? = nil, precision: String = "segment", source: TranscriptSource = .merged) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.precision = precision; self.source = source
    }
}

public struct TranscriptResult: Codable, Sendable {
    public var model: TranscriptModel
    public var revision: String
    public var segments: [TranscriptSegment]
    public var partial = false
    public var unavailableSources: [TranscriptSource] = []
    public var text: String { segments.map(\.text).joined(separator: "\n") }
}

public enum TranscriptRunState: String, Codable, Sendable {
    case queued, waitingForRecording, running, succeeded, failed, partial
    public var finished: Bool { self == .succeeded || self == .failed || self == .partial }
}

public struct TranscriptAttempt: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public var queuedAt: String
    public var startedAt: String
    public var finishedAt: String?
    public var elapsedSeconds: Double?
    public var executionSeconds = 0.0
    public var cpuSeconds: Double?
    public var peakResidentBytes: UInt64?
    public var resourceScope: String?
    public var observedChunks = 0
    public var completedAudioSeconds: Double?
    public var state: TranscriptRunState = .queued
    public var error: String?
}

public struct TranscriptSourceExecution: Codable, Sendable, Identifiable {
    public var id: String { source.rawValue }
    public var source: TranscriptSource
    public var state: TranscriptRunState = .queued
    public var error: String?
    public var queuedAt: String?
    public var completedChunks = 0
    public var cloudRequestID: String?
    public var cloudSubmission: String?
    public var cloudLogID: String?
    public var attempts: [TranscriptAttempt] = []

    public init(source: TranscriptSource) { self.source = source }
}

public struct TranscriptRun: Codable, Sendable, Identifiable {
    public var id: String { model.rawValue }
    public var model: TranscriptModel
    public var installation: LocalInstallation?
    public var revision: String
    public var sources: [TranscriptSourceExecution]
    public var state: TranscriptRunState {
        if sources.allSatisfy({ $0.state == .succeeded }) { return .succeeded }
        if sources.allSatisfy({ $0.state.finished }) {
            return sources.contains { $0.state == .succeeded || $0.state == .partial || $0.completedChunks > 0 } ? .partial : .failed
        }
        if sources.contains(where: { $0.state == .running }) { return .running }
        if sources.contains(where: { $0.state == .waitingForRecording }) { return .waitingForRecording }
        return .queued
    }
    public var error: String? {
        let failures = sources.compactMap { value in value.error.map { "\(value.source.name)：\($0)" } }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    public var completedChunks: Int { sources.reduce(0) { $0 + $1.completedChunks } }

    public init(model: TranscriptModel, installation: LocalInstallation? = nil, revision: String, sources: [TranscriptSource] = [.merged]) {
        self.model = model; self.installation = installation; self.revision = revision
        self.sources = sources.map(TranscriptSourceExecution.init)
    }
}

public struct TranscriptionTask: Codable, Sendable, Identifiable {
    public var schemaVersion = 1
    public var id: String
    public var inputPath: String
    public var inputSHA256: String
    public var sessionID: String?
    public var duration: Double
    public var createdAt: String
    public var primaryModel: TranscriptModel
    public var runs: [TranscriptRun]
    public var workerPID: Int32?
    public var lastLaunchAt: String?
    public var error: String?
    public var recognitionMode: RecognitionMode = .merged
    public var nativeSourceMapping = false
    public var finished: Bool { runs.allSatisfy { $0.state.finished } }
    public var state: String {
        if finished { return runs.allSatisfy { $0.state == .succeeded } ? "completed" : runs.contains { $0.state == .succeeded || $0.state == .partial } ? "partial" : "failed" }
        if runs.contains(where: { $0.state == .waitingForRecording }) { return "waitingForRecording" }
        return runs.contains { $0.state == .running } ? "running" : "queued"
    }
}

public struct ModelInstallationStatus: Codable, Sendable {
    public var model: TranscriptModel
    public var profile: String
    public var state: String
    public var message: String
    public var processID: Int32?
}

public struct TranscriptionFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum TranscriptComparison {
    public static func matching(_ segment: TranscriptSegment, in result: TranscriptResult) -> [TranscriptSegment] {
        result.segments.filter { $0.source == segment.source && (min($0.end, segment.end) > max($0.start, segment.start) || abs($0.start - segment.start) < 0.15) }
    }
    public static func differs(_ text: String, from other: String) -> Bool {
        func normalized(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        return normalized(text) != normalized(other)
    }
}

extension TranscriptionSettings {
    private enum CodingKeys: String, CodingKey { case schemaVersion, models, automatic, installations, profile, recognitionMode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        models = try c.decode([TranscriptModel].self, forKey: .models)
        automatic = try c.decode(Bool.self, forKey: .automatic)
        installations = try c.decode([String: LocalInstallation].self, forKey: .installations)
        profile = try c.decode(String.self, forKey: .profile)
        recognitionMode = try c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode) ?? .separate
    }
}

extension TranscriptSegment {
    private enum CodingKeys: String, CodingKey { case id, start, end, text, speaker, precision, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text); speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        precision = try c.decode(String.self, forKey: .precision)
        source = try c.decodeIfPresent(TranscriptSource.self, forKey: .source) ?? .merged
    }
}

extension TranscriptResult {
    private enum CodingKeys: String, CodingKey { case model, revision, segments, partial, unavailableSources }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(TranscriptModel.self, forKey: .model)
        revision = try c.decode(String.self, forKey: .revision)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        unavailableSources = try c.decodeIfPresent([TranscriptSource].self, forKey: .unavailableSources) ?? []
    }
}

extension TranscriptRun {
    private enum CodingKeys: String, CodingKey {
        case model, installation, revision, sources, state, error, completedChunks, cloudRequestID, cloudSubmission, cloudLogID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(TranscriptModel.self, forKey: .model)
        installation = try c.decodeIfPresent(LocalInstallation.self, forKey: .installation)
        revision = try c.decode(String.self, forKey: .revision)
        if let values = try c.decodeIfPresent([TranscriptSourceExecution].self, forKey: .sources) {
            guard !values.isEmpty, Set(values.map(\.source)).count == values.count else {
                throw DecodingError.dataCorruptedError(forKey: .sources, in: c, debugDescription: "音源执行列表无效。")
            }
            sources = values
        } else {
            var legacy = TranscriptSourceExecution(source: .merged)
            legacy.state = try c.decode(TranscriptRunState.self, forKey: .state)
            legacy.error = try c.decodeIfPresent(String.self, forKey: .error)
            legacy.completedChunks = try c.decodeIfPresent(Int.self, forKey: .completedChunks) ?? 0
            legacy.cloudRequestID = try c.decodeIfPresent(String.self, forKey: .cloudRequestID)
            legacy.cloudSubmission = try c.decodeIfPresent(String.self, forKey: .cloudSubmission)
            legacy.cloudLogID = try c.decodeIfPresent(String.self, forKey: .cloudLogID)
            sources = [legacy]
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model); try c.encodeIfPresent(installation, forKey: .installation)
        try c.encode(revision, forKey: .revision); try c.encode(sources, forKey: .sources)
        try c.encode(state, forKey: .state); try c.encodeIfPresent(error, forKey: .error)
        try c.encode(completedChunks, forKey: .completedChunks)
    }
}

extension TranscriptionTask {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, inputPath, inputSHA256, sessionID, duration, createdAt, primaryModel, runs
        case workerPID, lastLaunchAt, error, recognitionMode, nativeSourceMapping
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id); inputPath = try c.decode(String.self, forKey: .inputPath)
        inputSHA256 = try c.decode(String.self, forKey: .inputSHA256); sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        duration = try c.decode(Double.self, forKey: .duration); createdAt = try c.decode(String.self, forKey: .createdAt)
        primaryModel = try c.decode(TranscriptModel.self, forKey: .primaryModel); runs = try c.decode([TranscriptRun].self, forKey: .runs)
        workerPID = try c.decodeIfPresent(Int32.self, forKey: .workerPID)
        lastLaunchAt = try c.decodeIfPresent(String.self, forKey: .lastLaunchAt); error = try c.decodeIfPresent(String.self, forKey: .error)
        recognitionMode = try c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode) ?? .merged
        nativeSourceMapping = try c.decodeIfPresent(Bool.self, forKey: .nativeSourceMapping) ?? false
    }
}
