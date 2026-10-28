/// Inputs that fully describe one recording session.
public struct RecordingConfiguration: Codable, Sendable, Equatable {
    /// Directory that receives the recording file(s). Must already exist and
    /// be writable; there is no default.
    public var outputDirectory: String
    /// Also keep the raw microphone track as a separate file.
    public var keepRawMicrophone: Bool
    public var recognitionMode: RecognitionMode?

    public init(outputDirectory: String, keepRawMicrophone: Bool = false, recognitionMode: RecognitionMode? = nil) {
        self.outputDirectory = outputDirectory
        self.keepRawMicrophone = keepRawMicrophone
        self.recognitionMode = recognitionMode
    }
}

public enum MeetingTapeError: Error, Sendable, Equatable, CustomStringConvertible {
    case outDirectoryDoesNotExist(String)
    case outPathNotADirectory(String)
    case outDirectoryNotWritable(String)
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
        case .noActiveSession:
            return "no active recording session"
        case .failure(let reason):
            return reason
        }
    }
}
