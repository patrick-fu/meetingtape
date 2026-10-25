import Foundation
import MeetingTapeCore

struct DesktopFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor RecordingClient {
    private let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/meetingtape")

    func run(_ arguments: [String]) async throws -> SessionSnapshot? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DesktopFailure(message: "找不到录音组件，请重新构建 MeetingTape.app。")
        }
        let process = Process()
        let pipe = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        try? pipe.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        async let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let errorOutput = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let (data, errorData) = await (output, errorOutput)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DesktopFailure(message: String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        struct State: Decodable { let state: String; let schemaVersion: Int }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw DesktopFailure(message: "录音组件版本不兼容。") }
        if state.state == "idle" { return nil }
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
