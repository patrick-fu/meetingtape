import Foundation
import MeetingTapeTranscription
if CommandLine.arguments.dropFirst().first == "__automatic" {
    _ = setsid()
    let arguments = CommandLine.arguments
    guard arguments.count == 5 else { exit(2) }
    let names = arguments[4].split(separator: ",")
    let models = names.compactMap { TranscriptModel(rawValue: String($0)) }
    guard !models.isEmpty, models.count == names.count else { exit(2) }
    TranscriptionManager.automaticWork(input: arguments[2], sessionID: arguments[3], models: models)
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "__transcribe" {
    _ = setsid()
    guard CommandLine.arguments.count == 3 else { exit(2) }
    do { try TranscriptionManager.work(CommandLine.arguments[2]); exit(0) } catch { exit(4) }
}
if CommandLine.arguments.dropFirst().first == "__install" {
    _ = setsid()
    let arguments = CommandLine.arguments
    guard (5...6).contains(arguments.count), let model = TranscriptModel(rawValue: arguments[2]) else { exit(2) }
    do { try LocalModels.install(model: model, profile: arguments[3], reuse: arguments[4] == "reuse", reuseRoot: arguments.count == 6 ? arguments[5] : nil); exit(0) } catch { exit(4) }
}
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
