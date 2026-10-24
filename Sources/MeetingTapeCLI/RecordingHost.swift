import Darwin
import Foundation
import MeetingTapeCore

protocol HostSession: AnyObject, Sendable {
    func start(_ configuration: RecordingConfiguration) throws -> SessionSnapshot
    func snapshot() -> SessionSnapshot
    func stop() throws -> SessionSnapshot
}

extension RecordingSession: HostSession {}

final class RecordingHost: @unchecked Sendable {
    private let session: any HostSession
    private let paths: HostPaths
    private let lifecycle: SessionLock
    private var listener: Int32 = -1
    private let finishLock = NSLock()
    private var finalResponse: HostResponse?

    init(paths: HostPaths, session: any HostSession = RecordingSession()) throws {
        self.paths = paths
        self.session = session
        lifecycle = try SessionLock(directory: paths.directory, name: "session.lock")
    }

    func start(_ configuration: RecordingConfiguration) throws -> SessionSnapshot {
        listener = try HostTransport.socket()
        unlink(paths.socketPath)
        var target = try HostTransport.address(paths.socketPath)
        let bound = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw HostFailure("cannot listen on the local session socket") }
        let snapshot = try session.start(configuration)
        guard snapshot.state == .recording, snapshot.systemAvailable, snapshot.microphoneAvailable else {
            throw HostFailure(snapshot.failureReason ?? "audio capture did not become ready")
        }
        return snapshot
    }

    func serve() {
        let requests = DispatchGroup()
        let ending = HostEnding()
        while !ending.value {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = poll(&event, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                break
            }
            if result == 0 { continue }
            guard event.revents & Int16(POLLIN) != 0 else { break }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            requests.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(client); requests.leave() }
                var enabled: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                var stopping = false
                do {
                    let request = try HostTransport.read(HostRequest.self, from: client)
                    stopping = request == .stop
                    let response = stopping ? self.finish() : HostResponse(snapshot: self.session.snapshot())
                    try HostTransport.write(response, to: client)
                } catch {
                    try? HostTransport.write(HostResponse(error: String(describing: error)), to: client)
                }
                if stopping { ending.mark() }
            }
        }
        requests.wait()
    }

    func finish() -> HostResponse {
        finishLock.lock()
        defer { finishLock.unlock() }
        if let finalResponse { return finalResponse }
        do {
            let result = try session.stop()
            let response = HostResponse(snapshot: result, error: result.state == .completed ? nil : result.failureReason ?? "recording finalization failed")
            finalResponse = response
            return response
        } catch {
            let response = HostResponse(snapshot: session.snapshot(), error: String(describing: error))
            finalResponse = response
            return response
        }
    }

    deinit {
        if listener >= 0 { close(listener) }
        unlink(paths.socketPath)
        withExtendedLifetime(lifecycle) {}
    }
}

enum HostCommand {
    static func run(_ arguments: [String]) -> Never {
        var out: String?
        var ready: String?
        var keepRaw = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out", "--ready-file":
                guard index + 1 < arguments.count else { exit(ExitCode.usage.rawValue) }
                let option = arguments[index]
                index += 1
                if option == "--out" { out = arguments[index] } else { ready = arguments[index] }
            case "--keep-raw": keepRaw = true
            default: exit(ExitCode.usage.rawValue)
            }
            index += 1
        }
        guard let out, let ready else { exit(ExitCode.usage.rawValue) }
        _ = setsid()
        let signalQueue = DispatchQueue(label: "meetingtape.host.signals")
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let holder = HostHolder()
        let finish: @Sendable () -> Void = {
            let result = holder.finish()
            exit(result?.error == nil ? ExitCode.ok.rawValue : ExitCode.capture.rawValue)
        }
        termination.setEventHandler(handler: finish)
        interrupt.setEventHandler(handler: finish)
        termination.resume()
        interrupt.resume()
        let configuration = RecordingConfiguration(outputDirectory: out, keepRawMicrophone: keepRaw)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let host = try RecordingHost(paths: HostPaths())
                holder.set(host)
                let snapshot = try host.start(configuration)
                try publish(HostResponse(snapshot: snapshot), to: ready)
                host.serve()
                let response = host.finish()
                exit(response.error == nil ? ExitCode.ok.rawValue : ExitCode.capture.rawValue)
            } catch {
                _ = holder.finish()
                try? publish(HostResponse(error: String(describing: error)), to: ready)
                exit(ExitCode.capture.rawValue)
            }
        }
        withExtendedLifetime((termination, interrupt)) {
            RunLoop.main.run()
        }
        exit(ExitCode.capture.rawValue)
    }

    private static func publish(_ response: HostResponse, to path: String) throws {
        try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private final class HostHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var host: RecordingHost?

    func set(_ value: RecordingHost) {
        lock.lock()
        host = value
        lock.unlock()
    }

    func finish() -> HostResponse? {
        lock.lock()
        let value = host
        lock.unlock()
        return value?.finish()
    }
}

private final class HostEnding: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func mark() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}
