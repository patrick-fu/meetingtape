/// Version of the meetingtape components, surfaced by the CLI as --version.
public let meetingTapeVersion = "0.1.0"

/// Process exit codes. The CLI documents these and they are part of the
/// agent-facing contract, so they must stay stable.
public enum ExitCode: Int32, Sendable {
    /// Success (including informational answers such as "no active session").
    case ok = 0
    /// Invalid usage: unknown command or option, missing or invalid argument.
    case usage = 1
    /// Environment is not ready (doctor failure, unsupported macOS, no devices).
    case environment = 2
    /// An operation needs an active recording session and there is none.
    case noActiveSession = 3
    /// Audio capture failed (in scaffold builds: capture is not implemented).
    case capture = 4
}
