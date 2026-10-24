/// Inputs that fully describe one recording session.
public struct RecordingConfiguration: Codable, Sendable, Equatable {
    /// Directory that receives the recording file(s). Must already exist and
    /// be writable; there is no default.
    public var outputDirectory: String
    /// Also keep the raw microphone track as a separate file.
    public var keepRawMicrophone: Bool

    public init(outputDirectory: String, keepRawMicrophone: Bool = false) {
        self.outputDirectory = outputDirectory
        self.keepRawMicrophone = keepRawMicrophone
    }
}

public enum MeetingTapeError: Error, Sendable, Equatable, CustomStringConvertible {
    case outDirectoryDoesNotExist(String)
    case outPathNotADirectory(String)
    case outDirectoryNotWritable(String)
    case captureUnavailable
    case noActiveSession
    case failure(String)

    public var description: String {
        switch self {
        case .outDirectoryDoesNotExist(let path):
            return "--out directory does not exist: \(path)"
        case .outPathNotADirectory(let path):
            return "--out path is not a directory: \(path)"
        case .outDirectoryNotWritable(let path):
            return "--out directory is not writable: \(path)"
        case .captureUnavailable:
            return "audio capture is not available in this scaffold build"
        case .noActiveSession:
            return "no active recording session"
        case .failure(let reason):
            return reason
        }
    }
}

/// Seam between the CLI shell and the future capture core. The real engine
/// will implement CoreAudio tap capture (system audio) plus AVAudioEngine
/// capture (microphone) with 3A processing, mixed into one stereo file.
public protocol RecordingEngine: Sendable {
    func start(_ configuration: RecordingConfiguration) throws
    func stop() throws
}

/// Placeholder engine used until the capture core lands. Every call reports
/// unavailability instead of pretending to record.
public struct ScaffoldEngine: RecordingEngine, Sendable {
    public init() {}

    public func start(_ configuration: RecordingConfiguration) throws {
        throw MeetingTapeError.captureUnavailable
    }

    public func stop() throws {
        throw MeetingTapeError.noActiveSession
    }
}

public enum EngineFactory {
    public static func defaultEngine() -> RecordingEngine {
        ScaffoldEngine()
    }
}
