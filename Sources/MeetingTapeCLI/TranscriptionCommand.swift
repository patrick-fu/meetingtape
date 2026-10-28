import Foundation
import MeetingTapeTranscription

enum TranscriptionCommand {
    static let help = """
    Transcribe saved recordings with local Qwen/MOSS or Doubao 2.0 (BYOK).

    meetingtape transcribe models [--existing|--existing-root <runtime-directory>]
    meetingtape transcribe settings [--save-stdin]
    meetingtape transcribe install <qwen|moss> [--profile low-memory|standard] [--reuse] [--reuse-root <runtime-directory>]
    meetingtape transcribe credentials <status|save-stdin|remove|test>
    meetingtape transcribe start <saved-audio> [--models qwen,moss,doubao] [--mode separate|merged] [--allow-cloud]
    meetingtape transcribe list
    meetingtape transcribe status <task-id>
    meetingtape transcribe result <task-id> <qwen|moss|doubao> [--text]
    meetingtape transcribe retry <task-id> <qwen|moss|doubao> [--source system|microphone|merged]
    meetingtape transcribe export <session-id|task-id> --primary live|<task-id>:<model> [--include-versions] [--title <title>] [--output <file.md>]

    Commands return schema-based JSON. Settings and credentials are read from stdin
    when explicitly requested. Credentials use macOS Keychain; values are never returned.
    Cloud transcription uploads a mono copy to Doubao; --allow-cloud is required.
    Local model installation downloads pinned packages and model weights on demand.
    Completed transcripts persist independently for each selected model and source.
    Native recordings default to separate system/microphone recognition. Unknown
    external audio remains merged; separate mode requires native channel metadata.

    """

    static func run(_ arguments: [String]) -> RunResult {
        guard let action = arguments.first, action != "--help", action != "-h" else { return RunResult(exitCode: .ok, stdout: help) }
        let rest = Array(arguments.dropFirst()).filter { $0 != "--json" }
        do {
            let store = try TranscriptionStore()
            switch action {
            case "models":
                var inventory = try LocalModels.inventory(includeExisting: rest.contains("--existing"))
                if let index = rest.firstIndex(of: "--existing-root"), index + 1 < rest.count {
                    inventory.existingInstallations = LocalModels.existing(root: URL(fileURLWithPath: rest[index + 1]))
                }
                return try json(inventory)
            case "settings":
                if rest == ["--save-stdin"] {
                    let settings = try JSONDecoder().decode(TranscriptionSettings.self, from: input())
                    try store.saveSettings(settings)
                } else if !rest.isEmpty { throw TranscriptionFailure("Use settings [--save-stdin].") }
                return try json(store.settings())
            case "install":
                guard let first = rest.first, let model = TranscriptModel(rawValue: first), model.local else { throw TranscriptionFailure("Select qwen or moss.") }
                let profile: String
                if let index = rest.firstIndex(of: "--profile"), index + 1 < rest.count { profile = rest[index + 1] }
                else { profile = try LocalModels.inventory().recommendedProfile }
                let reuseRoot = rest.firstIndex(of: "--reuse-root").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
                try LocalModels.launch(model: model, profile: profile, reuse: rest.contains("--reuse"), reuseRoot: reuseRoot)
                return try json(["state": "installing", "model": model.rawValue])
            case "credentials":
                switch rest.first {
                case "status": return try json(["configured": TranscriptionCredentials.configured()])
                case "save-stdin": try TranscriptionCredentials.save(JSONDecoder().decode(DoubaoCredential.self, from: input())); return try json(["configured": true])
                case "remove": try TranscriptionCredentials.remove(); return try json(["configured": TranscriptionCredentials.configured()])
                case "test": try TranscriptionConnection.test(); return try json(["accepted": true])
                default: throw TranscriptionFailure("Use credentials status|save-stdin|remove|test.")
                }
            case "list": return try json(store.tasks().map { TaskResponse(task: (try? TranscriptionManager.status($0.id)) ?? $0) })
            case "start":
                guard let path = rest.first, !path.hasPrefix("--") else { throw TranscriptionFailure("Provide a saved audio path.") }
                var models: [TranscriptModel]?
                if let index = rest.firstIndex(of: "--models"), index + 1 < rest.count {
                    let names = rest[index + 1].split(separator: ",").map(String.init)
                    let values = names.compactMap(TranscriptModel.init(rawValue:))
                    guard values.count == names.count else { throw TranscriptionFailure("Unknown transcription model.") }
                    models = values
                }
                let chosen = try models ?? store.settings().models
                var mode: RecognitionMode?
                if let index = rest.firstIndex(of: "--mode") {
                    guard index + 1 < rest.count, let value = RecognitionMode(rawValue: rest[index + 1]) else { throw TranscriptionFailure("Use --mode separate|merged.") }
                    mode = value
                }
                if chosen.contains(.doubao), !rest.contains("--allow-cloud") { throw TranscriptionFailure("Doubao uploads audio; pass --allow-cloud to proceed.") }
                return try json(TaskResponse(task: TranscriptionManager.enqueue(input: path, models: chosen, mode: mode)))
            case "status":
                guard rest.count == 1 else { throw TranscriptionFailure("Provide one task ID.") }
                return try json(TaskResponse(task: TranscriptionManager.status(rest[0])))
            case "retry":
                guard rest.count >= 2, let model = TranscriptModel(rawValue: rest[1]) else { throw TranscriptionFailure("Provide task ID and model.") }
                var source: TranscriptSource?
                if rest.count != 2 {
                    guard rest.count == 4, rest[2] == "--source", let value = TranscriptSource(rawValue: rest[3]) else { throw TranscriptionFailure("Use retry <task-id> <model> [--source system|microphone|merged].") }
                    source = value
                }
                return try json(TaskResponse(task: TranscriptionManager.retry(rest[0], model: model, source: source)))
            case "result":
                guard rest.count >= 2, let model = TranscriptModel(rawValue: rest[1]) else { throw TranscriptionFailure("Provide task ID and model.") }
                let result = try store.result(rest[0], model: model)
                return rest.contains("--text") ? RunResult(exitCode: .ok, stdout: result.text + "\n") : try json(result)
            case "export":
                guard let id = rest.first, !id.hasPrefix("--") else { throw TranscriptionFailure("Provide a recording or task ID.") }
                var primary: String?, destination: String?, title = "录音转写", includeVersions = false
                var index = 1
                while index < rest.count {
                    let option = rest[index]
                    if option == "--include-versions" { includeVersions = true; index += 1; continue }
                    guard ["--primary", "--title", "--output"].contains(option), index + 1 < rest.count else { throw TranscriptionFailure("Unknown or incomplete export option: \(option)") }
                    switch option {
                    case "--primary": primary = rest[index + 1]
                    case "--title": title = rest[index + 1]
                    default: destination = rest[index + 1]
                    }
                    index += 2
                }
                let snapshot = try TranscriptExportSnapshot.load(id, title: title, store: store)
                guard let primary else { throw TranscriptionFailure("Choose --primary from: " + snapshot.versions.map(\.id).joined(separator: ", ")) }
                let markdown = try snapshot.markdown(primary: primary, includeVersions: includeVersions)
                if let destination {
                    try Data(markdown.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
                    return try json(["exported": true])
                }
                return RunResult(exitCode: .ok, stdout: markdown)
            default: throw TranscriptionFailure("Unknown transcription command. Run meetingtape help transcribe.")
            }
        } catch { return RunResult(exitCode: .capture, stderr: error.localizedDescription + "\n") }
    }

    private static func json<T: Encodable>(_ value: T) throws -> RunResult {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return RunResult(exitCode: .ok, stdout: String(decoding: try encoder.encode(value), as: UTF8.self) + "\n")
    }
    private static func input() throws -> Data {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 64 * 1024 else { throw TranscriptionFailure("Input is too large.") }
        return data
    }
}

private struct TaskResponse: Encodable {
    let task: TranscriptionTask
    enum CodingKeys: String, CodingKey { case state, finished }
    func encode(to encoder: Encoder) throws {
        try task.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task.state, forKey: .state)
        try container.encode(task.finished, forKey: .finished)
    }
}
