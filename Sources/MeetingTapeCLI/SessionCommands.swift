import Foundation
import MeetingTapeCore

enum StopCommand {
    static func run(_ arguments: [String], stop: () throws -> SessionSnapshot?) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: .ok, stdout: HelpText.stop)
        }
        guard arguments.isEmpty else { return RunResult(exitCode: .usage, stderr: "error: stop accepts no options\n") }
        do {
            guard let snapshot = try stop() else {
                return RunResult(exitCode: .noActiveSession, stderr: "error: no active recording session\n")
            }
            return RunResult(exitCode: .ok, stdout: "recording stopped\n" + snapshotText(snapshot))
        } catch {
            return RunResult(exitCode: .capture, stderr: "error: \(error)\n")
        }
    }
}

enum StatusCommand {
    static func run(_ arguments: [String], status: () throws -> SessionSnapshot?) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: .ok, stdout: HelpText.status)
        }
        guard arguments.isEmpty || arguments == ["--json"] else {
            return RunResult(exitCode: .usage, stderr: "error: status accepts only --json\n")
        }
        do {
            let snapshot = try status()
            if arguments == ["--json"] {
                guard let snapshot else {
                    return RunResult(exitCode: .ok, stdout: "{\"schemaVersion\":1,\"state\":\"idle\"}\n")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return RunResult(exitCode: .ok, stdout: String(decoding: try encoder.encode(snapshot), as: UTF8.self) + "\n")
            }
            return RunResult(exitCode: .ok, stdout: snapshot.map(snapshotText) ?? "status: no active recording session\n")
        } catch {
            return RunResult(exitCode: .capture, stderr: "error: \(error)\n")
        }
    }
}

enum RecoverCommand {
    static func run(_ arguments: [String], recover: (String, String) throws -> SessionSnapshot) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: .ok, stdout: HelpText.recover)
        }
        guard arguments.count == 3, arguments[1] == "--out", !arguments[0].hasPrefix("-") else {
            return RunResult(exitCode: .usage, stderr: "error: usage: meetingtape recover <recovery-directory> --out <existing-directory>\n")
        }
        do {
            let snapshot = try recover(arguments[0], arguments[2])
            return RunResult(exitCode: .ok, stdout: "recording recovered\n" + snapshotText(snapshot))
        } catch {
            return RunResult(exitCode: .capture, stderr: "error: \(error)\n")
        }
    }
}
