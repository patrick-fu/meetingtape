import Foundation
import MeetingTapeCore

enum StartCommand {
    static func run(_ arguments: [String]) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.start)
        }

        var out: String?
        var keepRaw = false

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                guard index + 1 < arguments.count else {
                    return usage("error: --out requires a directory argument\n")
                }
                index += 1
                out = arguments[index]
            case "--keep-raw":
                keepRaw = true
            default:
                return usage("error: unknown option '\(arguments[index])'\nrun 'meetingtape help start' for usage\n")
            }
            index += 1
        }

        guard let out else {
            return usage("error: --out is required and no default output directory exists\nrun 'meetingtape help start' for usage\n")
        }

        // Validate the output directory up front; the CLI has no side effects
        // on it until capture actually starts.
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: out, isDirectory: &isDirectory) else {
            return usage("error: \(MeetingTapeError.outDirectoryDoesNotExist(out))\n")
        }
        guard isDirectory.boolValue else {
            return usage("error: \(MeetingTapeError.outPathNotADirectory(out))\n")
        }
        guard fileManager.isWritableFile(atPath: out) else {
            return usage("error: \(MeetingTapeError.outDirectoryNotWritable(out))\n")
        }

        let configuration = RecordingConfiguration(outputDirectory: out, keepRawMicrophone: keepRaw)
        do {
            try EngineFactory.defaultEngine().start(configuration)
            return RunResult(exitCode: ExitCode.ok, stdout: "recording started\n")
        } catch {
            return RunResult(exitCode: ExitCode.capture, stderr: "error: \(error)\n")
        }
    }

    private static func usage(_ message: String) -> RunResult {
        RunResult(exitCode: ExitCode.usage, stderr: message)
    }
}
