import Foundation
import MeetingTapeCore

enum StopCommand {
    static func run(_ arguments: [String], stop: () throws -> SessionSnapshot?, stopSession: ((String) throws -> SessionSnapshot?)? = nil) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: .ok, stdout: HelpText.stop)
        }
        let json = arguments.contains("--json")
        let values = arguments.filter { $0 != "--json" }
        let expected: String?
        if values.isEmpty { expected = nil }
        else if values.count == 2, values[0] == "--session", !values[1].isEmpty, stopSession != nil { expected = values[1] }
        else { return RunResult(exitCode: .usage, stderr: "error: usage: meetingtape stop [--session <id>] [--json]\n") }
        do {
            let value: SessionSnapshot?
            if let expected { value = try stopSession!(expected) }
            else { value = try stop() }
            guard let snapshot = value else {
                return RunResult(exitCode: .noActiveSession, stderr: "error: no active recording session\n")
            }
            return RunResult(exitCode: .ok, stdout: try snapshotOutput(snapshot, json: json, prefix: "recording stopped\n"))
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
        let json = arguments.last == "--json"
        let values = json ? Array(arguments.dropLast()) : arguments
        guard values.count == 3, values[1] == "--out", !values[0].hasPrefix("-") else {
            return RunResult(exitCode: .usage, stderr: "error: usage: meetingtape recover <recovery-directory> --out <existing-directory>\n")
        }
        do {
            let snapshot = try recover(values[0], values[2])
            return RunResult(exitCode: .ok, stdout: try snapshotOutput(snapshot, json: json, prefix: "recording recovered\n"))
        } catch {
            return RunResult(exitCode: .capture, stderr: "error: \(error)\n")
        }
    }
}
