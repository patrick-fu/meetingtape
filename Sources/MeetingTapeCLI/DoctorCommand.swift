import Foundation
import MeetingTapeCore

/// Minimum macOS version for the CoreAudio tap API.
private let requiredMajor = 14
private let requiredMinor = 2

enum MacOSVersionCheck {
    static func isSupported(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion > requiredMajor
            || (version.majorVersion == requiredMajor && version.minorVersion >= requiredMinor)
    }

    static func describe(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// Everything doctor needs, collected up front so the check logic stays pure
/// and testable without touching CoreAudio on the test runner.
struct DoctorSnapshot {
    var osVersion: OperatingSystemVersion
    var deviceCounts: (inputs: Int, outputs: Int)?
    var deviceEnumerationFailed: Bool
}

struct DoctorLine {
    enum Kind { case ok, fail, note }
    var kind: Kind
    var text: String
}

enum DoctorCommand {
    static func run(_ arguments: [String]) -> RunResult {
        if arguments.contains("-h") || arguments.contains("--help") {
            return RunResult(exitCode: ExitCode.ok, stdout: HelpText.doctor)
        }

        var out: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                guard index + 1 < arguments.count else {
                    return RunResult(exitCode: ExitCode.usage, stderr: "error: --out requires a directory argument\n")
                }
                index += 1
                out = arguments[index]
            default:
                return RunResult(
                    exitCode: ExitCode.usage,
                    stderr: "error: unknown option '\(arguments[index])'\nrun 'meetingtape help doctor' for usage\n"
                )
            }
            index += 1
        }

        let counts = CoreAudioDevices.deviceCounts()
        let snapshot = DoctorSnapshot(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            deviceCounts: counts,
            deviceEnumerationFailed: counts == nil
        )
        return report(snapshot: snapshot, outDirectory: out)
    }

    static func report(snapshot: DoctorSnapshot, outDirectory: String?) -> RunResult {
        var lines: [DoctorLine] = []
        let supported = MacOSVersionCheck.isSupported(snapshot.osVersion)
        lines.append(DoctorLine(
            kind: supported ? .ok : .fail,
            text: supported
                ? "macOS \(MacOSVersionCheck.describe(snapshot.osVersion)) (requires 14.2 or newer)"
                : "macOS \(MacOSVersionCheck.describe(snapshot.osVersion)) is too old (requires 14.2 or newer)"
        ))

        if snapshot.deviceEnumerationFailed {
            lines.append(DoctorLine(kind: .fail, text: "audio devices could not be enumerated"))
        } else {
            let counts = snapshot.deviceCounts!
            let enough = counts.inputs > 0 && counts.outputs > 0
            lines.append(DoctorLine(
                kind: enough ? .ok : .fail,
                text: "audio devices: \(counts.inputs) input, \(counts.outputs) output (needs at least one of each)"
            ))
        }

        lines.append(DoctorLine(
            kind: .note,
            text: "microphone and audio-capture permission prompts appear on first real capture"
        ))

        if let outDirectory {
            var isDirectory: ObjCBool = false
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: outDirectory, isDirectory: &isDirectory) {
                lines.append(DoctorLine(kind: .fail, text: MeetingTapeError.outDirectoryDoesNotExist(outDirectory).description))
            } else if !isDirectory.boolValue {
                lines.append(DoctorLine(kind: .fail, text: MeetingTapeError.outPathNotADirectory(outDirectory).description))
            } else if !fileManager.isWritableFile(atPath: outDirectory) {
                lines.append(DoctorLine(kind: .fail, text: MeetingTapeError.outDirectoryNotWritable(outDirectory).description))
            } else {
                lines.append(DoctorLine(kind: .ok, text: "--out directory is writable: \(outDirectory)"))
            }
        }

        let failed = lines.contains { $0.kind == .fail }
        var stdout = ""
        for line in lines {
            let prefix: String
            switch line.kind {
            case .ok: prefix = "ok: "
            case .fail: prefix = "fail: "
            case .note: prefix = "note: "
            }
            stdout += prefix + line.text + "\n"
        }
        stdout += failed ? "doctor: environment not ready\n" : "doctor: environment ready\n"
        return RunResult(exitCode: failed ? ExitCode.environment : ExitCode.ok, stdout: stdout)
    }
}
