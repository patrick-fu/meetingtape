import MeetingTapeCore

public struct RunResult: Sendable {
    public let exitCode: ExitCode
    public let stdout: String
    public let stderr: String

    public init(exitCode: ExitCode, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum MeetingTapeCLI {
    public static func run(_ arguments: [String]) -> RunResult {
        run(arguments, services: .live)
    }

    static func run(_ arguments: [String], services: CommandServices) -> RunResult {
        guard let command = arguments.first else {
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.overview)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--help", "-h":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.overview)
        case "help":
            return help(rest)
        case "--version":
            return RunResult(exitCode: ExitCode.ok, stdout: "meetingtape \(meetingTapeVersion)\n")
        case "start":
            return StartCommand.run(rest, start: services.start)
        case "stop":
            return StopCommand.run(rest, stop: services.stop, stopSession: services.stopSession)
        case "status":
            return StatusCommand.run(rest, status: services.status)
        case "doctor":
            return DoctorCommand.run(rest)
        case "recover":
            return RecoverCommand.run(rest, recover: services.recover)
        default:
            return RunResult(
                exitCode: ExitCode.usage,
                stderr: "error: unknown command '\(command)'\nrun 'meetingtape --help' to list commands\n"
            )
        }
    }

    private static func help(_ rest: [String]) -> RunResult {
        guard let topic = rest.first else {
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.overview)
        }
        switch topic {
        case "start":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.start)
        case "stop":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.stop)
        case "status":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.status)
        case "doctor":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.doctor)
        case "recover":
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.recover)
        case "--version":
            return RunResult(exitCode: ExitCode.ok, stdout: "meetingtape \(meetingTapeVersion)\n")
        default:
            return RunResult(
                exitCode: ExitCode.usage,
                stderr: "error: no help topic '\(topic)'\nrun 'meetingtape --help' to list commands\n"
            )
        }
    }
}
