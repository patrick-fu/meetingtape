import Foundation
import MeetingTapeCore

struct DesktopFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor RecordingClient {
    private let executable: URL

    init(executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/meetingtape")) {
        self.executable = executable
    }

    func run(_ arguments: [String]) async throws -> SessionSnapshot? {
        let data = try await data(arguments)
        struct State: Decodable { let state: String; let schemaVersion: Int }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw DesktopFailure(message: "录音组件版本不兼容。") }
        if state.state == "idle" { return nil }
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func data(_ arguments: [String], input: Data? = nil) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DesktopFailure(message: "找不到录音组件，请重新构建 MeetingTape.app。")
        }
        let process = Process()
        defer { withExtendedLifetime(process) {} }
        let pipe = Pipe()
        let errors = Pipe()
        let standardInput = input.map { _ in Pipe() }
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = (standardInput as Any?) ?? FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = errors
        async let exitStatus: Int32 = withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            defer {
                try? pipe.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error); return }
            if let standardInput, let input {
                try? standardInput.fileHandleForWriting.write(contentsOf: input)
                try? standardInput.fileHandleForWriting.close()
            }
        }
        async let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let errorOutput = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let (data, errorData, status) = try await (output, errorOutput, exitStatus)
        guard status == 0 else {
            let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopFailure(message: message.isEmpty ? "录音组件异常退出（状态 \(status)）。" : message)
        }
        return data
    }
}
