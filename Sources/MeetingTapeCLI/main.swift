import Foundation
if CommandLine.arguments.dropFirst().first == "__host" {
    HostCommand.run(Array(CommandLine.arguments.dropFirst(2)))
}
let result = MeetingTapeCLI.run(Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode.rawValue)
