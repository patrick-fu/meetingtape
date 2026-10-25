import Foundation

public enum AudioSource: String, Codable, Sendable {
    case system
    case microphone
}

public enum RecordingState: String, Codable, Sendable {
    case starting
    case recording
    case interrupted
    case stopping
    case finalizing
    case completed
    case failed
}

public struct RecordingInterval: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var source: AudioSource?
    public var reason: String

    public init(startSeconds: Double, endSeconds: Double, source: AudioSource? = nil, reason: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.source = source
        self.reason = reason
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var sessionID: String
    public var processID: Int32
    public var state: RecordingState = .starting
    public var startedAt: String
    public var elapsedSeconds = 0.0
    public var committedSeconds = 0.0
    public var outputPath: String?
    public var rawOutputPath: String?
    public var recoveryPath: String
    public var systemAvailable = false
    public var microphoneAvailable = false
    public var systemLevel: Double?
    public var microphoneLevel: Double?
    public var interruptions: [RecordingInterval] = []
    public var degradedIntervals: [RecordingInterval] = []
    public var failureReason: String?
    public var recoveryNote: String?

    public init(sessionID: String = UUID().uuidString.lowercased(), processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                startedAt: String = ISO8601DateFormatter().string(from: Date()), recoveryPath: String) {
        self.sessionID = sessionID
        self.processID = processID
        self.startedAt = startedAt
        self.recoveryPath = recoveryPath
    }
}
