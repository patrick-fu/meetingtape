import Darwin
import Foundation
import MeetingTapeCore

struct CommandServices {
    var start: (RecordingConfiguration) throws -> SessionSnapshot
    var status: () throws -> SessionSnapshot?
    var stop: () throws -> SessionSnapshot?
    var recover: (String, String) throws -> SessionSnapshot

    static var live: CommandServices {
        CommandServices(
            start: HostClient.start,
            status: { try HostClient.snapshot(.status) },
            stop: { try HostClient.snapshot(.stop) },
            recover: { try RecordingRecovery.recover(directory: $0, outputDirectory: $1) }
        )
    }
}

enum HostClient {
    static func start(_ configuration: RecordingConfiguration) throws -> SessionSnapshot {
        let paths = try HostPaths()
        let startup = try SessionLock(directory: paths.directory, name: "startup.lock")
        defer { withExtendedLifetime(startup) {} }
        do {
            let available = try SessionLock(directory: paths.directory, name: "session.lock")
            withExtendedLifetime(available) {}
        }
        let ready = paths.directory.appendingPathComponent("ready-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ready) }
        let child = Process()
        guard let executable = Bundle.main.executableURL else { throw HostFailure("cannot locate the recording host executable") }
        child.executableURL = executable.resolvingSymlinksInPath()
        child.arguments = ["__host", "--out", configuration.outputDirectory, "--ready-file", ready.path]
            + (configuration.keepRawMicrophone ? ["--keep-raw"] : [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        var confirmed = false
        defer { if !confirmed && child.isRunning { child.terminate() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: ready) {
                let response = try JSONDecoder().decode(HostResponse.self, from: data)
                if let error = response.error { throw HostFailure(error) }
                guard let snapshot = response.snapshot, snapshot.state == .recording,
                      snapshot.systemAvailable, snapshot.microphoneAvailable, child.isRunning else {
                    throw HostFailure("recording host failed its readiness check")
                }
                confirmed = true
                return snapshot
            }
            guard child.isRunning else { throw HostFailure("recording host exited before audio capture became ready") }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw HostFailure("audio capture did not become ready within 30 seconds; the host was asked to stop")
    }

    static func snapshot(_ request: HostRequest) throws -> SessionSnapshot? {
        guard let response = try HostTransport.request(request, paths: HostPaths()) else { return nil }
        if let error = response.error {
            let recovery = response.snapshot.map { "; recovery materials: \($0.recoveryPath)" } ?? ""
            throw HostFailure(error + recovery)
        }
        guard let snapshot = response.snapshot else { throw HostFailure("recording host returned no session state") }
        return snapshot
    }
}

func snapshotText(_ snapshot: SessionSnapshot) -> String {
    var text = "status: \(snapshot.state.rawValue)\nsession: \(snapshot.sessionID)\nelapsed: \(String(format: "%.2f", snapshot.elapsedSeconds)) seconds\n"
    if let path = snapshot.outputPath { text += "output: \(path)\n" }
    if let path = snapshot.rawOutputPath { text += "raw microphone: \(path)\n" }
    if let reason = snapshot.failureReason { text += "failure: \(reason)\n" }
    if snapshot.state != .completed { text += "recovery: \(snapshot.recoveryPath)\n" }
    if !snapshot.interruptions.isEmpty { text += "interruptions: \(snapshot.interruptions.count)\n" }
    if !snapshot.degradedIntervals.isEmpty { text += "degraded intervals: \(snapshot.degradedIntervals.count)\n" }
    return text
}
