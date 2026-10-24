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
            recover: HostClient.recover
        )
    }
}

enum HostClient {
    static func recover(_ directory: String, _ outputDirectory: String) throws -> SessionSnapshot {
        let snapshot = try RecordingRecovery.recover(directory: directory, outputDirectory: outputDirectory)
        if let paths = try? HostPaths() {
            try? SessionCache.store(snapshot, paths: paths, replacing: snapshot.sessionID)
        }
        return snapshot
    }

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
        defer {
            if !confirmed && child.isRunning {
                child.terminate()
                let shutdownDeadline = ProcessInfo.processInfo.systemUptime + 1
                while child.isRunning && ProcessInfo.processInfo.systemUptime < shutdownDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
        }
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
        throw HostFailure("audio capture did not become ready within 30 seconds; the host was stopped")
    }

    static func snapshot(_ request: HostRequest) throws -> SessionSnapshot? {
        let paths = try HostPaths()
        guard let response = try HostTransport.request(request, paths: paths) else {
            guard request == .status,
                  let data = try? Data(contentsOf: paths.directory.appendingPathComponent("last-session.json")),
                  var previous = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return nil }
            if previous.state == .completed { return nil }
            if previous.state != .failed {
                previous.state = .failed
                previous.failureReason = "recording host exited unexpectedly; use 'meetingtape help recover' to preserve available audio"
            }
            return previous
        }
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
    if let note = snapshot.recoveryNote { text += "recovery note: \(note)\n" }
    if snapshot.state != .completed { text += "recovery: \(snapshot.recoveryPath)\n" }
    if !snapshot.interruptions.isEmpty { text += "interruptions: \(snapshot.interruptions.count)\n" }
    if !snapshot.degradedIntervals.isEmpty { text += "degraded intervals: \(snapshot.degradedIntervals.count)\n" }
    if snapshot.state == .completed && FileManager.default.fileExists(atPath: snapshot.recoveryPath) {
        text += "warning: temporary materials remain at \(snapshot.recoveryPath)\n"
    }
    return text
}
