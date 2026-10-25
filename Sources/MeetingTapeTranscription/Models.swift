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
    public init() {}
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var precision: String
    public init(id: Int, start: Double, end: Double, text: String, speaker: String? = nil, precision: String = "segment") {
        self.id = id; self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.precision = precision
    }
}

public struct TranscriptResult: Codable, Sendable {
    public var model: TranscriptModel
    public var revision: String
    public var segments: [TranscriptSegment]
    public var text: String { segments.map(\.text).joined(separator: "\n") }
}

public enum TranscriptRunState: String, Codable, Sendable {
    case queued, waitingForRecording, running, succeeded, failed
}

public struct TranscriptRun: Codable, Sendable, Identifiable {
    public var id: String { model.rawValue }
    public var model: TranscriptModel
    public var state: TranscriptRunState = .queued
    public var installation: LocalInstallation?
    public var revision: String
    public var error: String?
    public var completedChunks = 0
    public var cloudRequestID: String?
    public var cloudSubmission: String?
    public var cloudLogID: String?
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
    public var finished: Bool { runs.allSatisfy { $0.state == .succeeded || $0.state == .failed } }
    public var state: String {
        if finished { return runs.allSatisfy { $0.state == .succeeded } ? "completed" : runs.contains { $0.state == .succeeded } ? "partial" : "failed" }
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
        result.segments.filter { min($0.end, segment.end) > max($0.start, segment.start) || abs($0.start - segment.start) < 0.15 }
    }
    public static func differs(_ text: String, from other: String) -> Bool {
        func normalized(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        return normalized(text) != normalized(other)
    }
}
