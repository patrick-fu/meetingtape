import AppKit
import Foundation
import IOKit.pwr_mgt

private final class SpeechJob: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[Float], Error>?
    let finished = DispatchSemaphore(value: 0)

    func finish(_ value: Result<[Float], Error>) {
        lock.lock()
        result = value
        lock.unlock()
        finished.signal()
    }

    func read() -> Result<[Float], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class SpeechGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.paaatrickfu.meetingtape.speech")
    private var processor: SpeechProcessor?
    private var bypassReason: String?
    private var pending: SpeechJob?

    init() {
        do { processor = try SpeechProcessor() }
        catch {
            processor = nil
            bypassReason = "speech processing unavailable: \(error)"
        }
    }

    func process(microphone: [Float], left: [Float], right: [Float]) -> (samples: [Float], reason: String?) {
        if let pending, pending.read() != nil {
            self.pending = nil
            queue.sync {
                do { processor = try SpeechProcessor(); bypassReason = nil }
                catch { bypassReason = "speech processing reset failed: \(error)" }
            }
        }
        guard processor != nil, bypassReason == nil else {
            return (microphone, bypassReason ?? "speech processing unavailable")
        }
        let job = SpeechJob()
        queue.async { [self] in
            job.finish(Result { try self.processor!.process(microphone: microphone, referenceLeft: left,
                                                       referenceRight: right, delayMilliseconds: 0) })
        }
        guard job.finished.wait(timeout: .now() + .milliseconds(30)) == .success else {
            pending = job
            bypassReason = "speech processing exceeded its deadline"
            return (microphone, bypassReason)
        }
        switch job.read()! {
        case .success(let output): return (output, nil)
        case .failure(let error):
            bypassReason = "speech processing failed: \(error)"
            return (microphone, bypassReason)
        }
    }

    func reset() {
        guard bypassReason == nil else { return }
        queue.sync {
            do { processor = try SpeechProcessor() }
            catch { bypassReason = "speech processing reset failed: \(error)" }
        }
    }
}

public final class RecordingSession: @unchecked Sendable {
    private enum PreservationWatch {
        case stopped
        case awake(lastCommit: Double)
        case sleeping
    }

    private let queue = DispatchQueue(label: "com.paaatrickfu.meetingtape.session", qos: .userInitiated)
    private let statusLock = NSLock()
    private var published: SessionSnapshot?
    private var watchdogFailure: String?
    private var preservationWatch = PreservationWatch.stopped
    private var report: SessionSnapshot?
    private var clock = SessionClock()
    private var capture = AudioCapture()
    private var timeline = CaptureTimeline()
    private var speech = SpeechGate()
    private var store: RecoveryStore?
    private var configuration: RecordingConfiguration?
    private var timer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var nextFrame: Int64 = 0
    private var lastCheckpoint = 0.0
    private var lastRefresh = 0.0
    private var bothUnavailableSince: Double?
    private var sleepingSince: Double?
    private var assertion: IOPMAssertionID = 0

    public init() {}

    public func start(_ configuration: RecordingConfiguration) throws -> SessionSnapshot {
        try queue.sync {
            guard report == nil else { throw MeetingTapeError.failure("a recording session already exists") }
            try Self.validateOutput(configuration.outputDirectory)
            self.configuration = configuration
            let id = UUID().uuidString.lowercased()
            let recovery = URL(fileURLWithPath: configuration.outputDirectory, isDirectory: true)
                .appendingPathComponent(".meetingtape-\(id).recovery", isDirectory: true)
            var initial = SessionSnapshot(sessionID: id, recoveryPath: recovery.path)
            clock = SessionClock()
            do {
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                store = try RecoveryStore(directory: recovery, keepRaw: configuration.keepRawMicrophone, snapshot: initial)
                try capture.start()
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var health = capture.health()
                while (!health.systemAvailable || !health.microphoneAvailable) && health.fatalError == nil && ProcessInfo.processInfo.systemUptime < deadline {
                    try ingest()
                    Thread.sleep(forTimeInterval: 0.01)
                    health = capture.health()
                }
                guard health.systemAvailable, health.microphoneAvailable, health.fatalError == nil else {
                    throw MeetingTapeError.failure(health.fatalError ?? health.systemReason ?? health.microphoneReason ?? "audio capture is unavailable")
                }
                initial.state = .recording
                initial.systemAvailable = true
                initial.microphoneAvailable = true
                report = initial
                try checkpoint()
                acquirePowerAssertion()
                observeSleep()
                startTimers()
                publish()
                return report!
            } catch {
                capture.stop()
                initial.state = .failed
                initial.failureReason = String(describing: error)
                report = initial
                _ = try? store?.checkpoint(initial)
                store = nil
                publish()
                throw MeetingTapeError.failure("\(error); recovery materials: \(recovery.path)")
            }
        }
    }

    public func snapshot() -> SessionSnapshot {
        statusLock.lock()
        defer { statusLock.unlock() }
        var value = published ?? SessionSnapshot(recoveryPath: "")
        if let watchdogFailure {
            value.state = .failed
            value.failureReason = watchdogFailure
        }
        return value
    }

    public func stop() throws -> SessionSnapshot {
        try queue.sync { try finish() }
    }

    private func startTimers() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.paaatrickfu.meetingtape.watchdog"))
        watchdog.schedule(deadline: .now() + 1, repeating: .milliseconds(100))
        watchdog.setEventHandler { [weak self] in self?.checkBudget() }
        watchdog.resume()
        self.watchdog = watchdog
    }

    private func checkBudget() {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard let published, case .awake(let lastCommit) = preservationWatch else { return }
        if ProcessInfo.processInfo.systemUptime - lastCommit > 3.5 {
            watchdogFailure = "recording preservation exceeded its five-second budget; retained recovery materials: \(published.recoveryPath)"
        }
    }

    private func tick() {
        guard let state = report?.state, state == .recording || state == .interrupted, sleepingSince == nil else { return }
        do {
            statusLock.lock()
            let failed = watchdogFailure
            statusLock.unlock()
            if let failed { throw MeetingTapeError.failure(failed) }
            let now = clock.elapsed
            if now - lastRefresh >= 0.5 {
                do { try capture.refreshIfNeeded() }
                catch { report?.failureReason = "capture retry: \(error)" }
                lastRefresh = now
            }
            try ingest()
            let health = capture.health()
            if let fatal = health.fatalError { throw MeetingTapeError.failure(fatal) }
            report?.systemAvailable = health.systemAvailable
            report?.microphoneAvailable = health.microphoneAvailable
            if !health.systemAvailable && !health.microphoneAvailable {
                if bothUnavailableSince == nil { bothUnavailableSince = now }
                if now - bothUnavailableSince! > 30 {
                    throw MeetingTapeError.failure("both audio sources have been unavailable for more than 30 awake seconds")
                }
            } else { bothUnavailableSince = nil }
            report?.state = health.systemAvailable && health.microphoneAvailable ? .recording : .interrupted
            let target = max(0, Int64((now - 0.4) * 48_000)) / 480 * 480
            try render(until: target, health: health)
            report?.elapsedSeconds = now
            if now - lastCheckpoint >= 0.5 { try checkpoint() }
            publish()
        } catch { fail(error) }
    }

    private func ingest() throws {
        for packet in capture.drain() {
            let frame = clock.frame(for: packet.hostTime)
            guard frame <= Int64((clock.elapsed + 1) * 48_000) else {
                throw MeetingTapeError.failure("captured audio timestamp is outside the session clock")
            }
            try timeline.insert(packet, frame: frame)
        }
    }

    private func render(until target: Int64, health: CaptureHealth) throws {
        while nextFrame + 480 <= target {
            let audio = timeline.render(at: nextFrame, count: 480)
            let beginning = Double(nextFrame) / 48_000
            let end = beginning + 0.01
            if !audio.hasSystem {
                addInterval(start: beginning, end: end, source: .system,
                            reason: health.systemReason ?? "system audio frames unavailable", degraded: false)
            }
            if !audio.hasMicrophone {
                addInterval(start: beginning, end: end, source: .microphone,
                            reason: health.microphoneReason ?? "microphone frames unavailable", degraded: false)
            }
            if audio.hasAnyAudio {
                var mic = audio.microphone
                if audio.hasMicrophone {
                    if audio.hasSystem {
                        let processed = speech.process(microphone: mic, left: audio.systemLeft, right: audio.systemRight)
                        mic = processed.samples
                        if let reason = processed.reason {
                            addInterval(start: beginning, end: end, source: .microphone, reason: reason, degraded: true)
                        }
                    } else {
                        addInterval(start: beginning, end: end, source: .microphone,
                                    reason: "echo-cancellation reference unavailable", degraded: true)
                    }
                } else if audio.hasAnyMicrophone {
                    addInterval(start: beginning, end: end, source: .microphone,
                                reason: "microphone frame gap", degraded: true)
                }
                var stereo = [Float](repeating: 0, count: 960)
                for index in 0..<480 {
                    stereo[index * 2] = (audio.systemLeft[index] + audio.systemRight[index]) * 0.5
                    stereo[index * 2 + 1] = mic[index]
                }
                try store!.append(stereo: stereo,
                                  rawMicrophone: configuration!.keepRawMicrophone ? audio.microphone : nil,
                                  at: nextFrame)
            }
            nextFrame += 480
        }
    }

    private func addInterval(start: Double, end: Double, source: AudioSource?, reason: String, degraded: Bool) {
        guard var value = report else { return }
        var intervals = degraded ? value.degradedIntervals : value.interruptions
        if let index = intervals.lastIndex(where: { $0.source == source && $0.reason == reason && abs($0.endSeconds - start) < 0.0001 }) {
            intervals[index].endSeconds = end
        } else {
            intervals.append(RecordingInterval(startSeconds: start, endSeconds: end, source: source, reason: reason))
        }
        if degraded { value.degradedIntervals = intervals } else { value.interruptions = intervals }
        report = value
    }

    private func checkpoint() throws {
        guard var value = report, let store else { return }
        let elapsed = value.elapsedSeconds
        value.committedSeconds = Double(nextFrame) / 48_000
        value.elapsedSeconds = value.committedSeconds
        _ = try store.checkpoint(value)
        value.elapsedSeconds = elapsed
        report = value
        lastCheckpoint = clock.elapsed
        statusLock.lock()
        if case .sleeping = preservationWatch {} else {
            preservationWatch = .awake(lastCommit: ProcessInfo.processInfo.systemUptime)
        }
        statusLock.unlock()
    }

    private func fail(_ error: Error) {
        timer?.cancel()
        timer = nil
        capture.stop()
        report?.state = .failed
        report?.elapsedSeconds = Double(nextFrame) / 48_000
        report?.failureReason = String(describing: error)
        publish()
        _ = try? checkpoint()
        releaseResources()
        store = nil
        publish()
    }

    private func finish() throws -> SessionSnapshot {
        statusLock.lock()
        let budgetFailure = watchdogFailure
        statusLock.unlock()
        if let budgetFailure, report?.state != .failed { fail(MeetingTapeError.failure(budgetFailure)) }
        if let fatal = capture.health().fatalError, report?.state != .failed { fail(MeetingTapeError.failure(fatal)) }
        guard let value = report else { throw MeetingTapeError.noActiveSession }
        if value.state == .completed { return value }
        if value.state == .failed {
            throw MeetingTapeError.failure("\(value.failureReason ?? "recording failed"); recovery materials: \(value.recoveryPath)")
        }
        timer?.cancel()
        timer = nil
        do {
            report?.state = .stopping
            if sleepingSince == nil {
                try ingest()
                capture.stop()
                try ingest()
                if let fatal = capture.health().fatalError { throw MeetingTapeError.failure(fatal) }
                let end = Int64(clock.elapsed * 48_000) / 480 * 480
                try render(until: end, health: capture.health())
                report?.elapsedSeconds = Double(end) / 48_000
            } else {
                let end = clock.elapsed
                addInterval(start: sleepingSince!, end: end, source: nil, reason: "system sleep", degraded: false)
                nextFrame = Int64(end * 48_000)
                report?.elapsedSeconds = Double(nextFrame) / 48_000
            }
            try checkpoint()
            report?.state = .finalizing
            publish()
            releaseResources()
            let final = try store!.finalize(report!, outputDirectory: URL(fileURLWithPath: configuration!.outputDirectory))
            report = final
            store = nil
            publish()
            return final
        } catch {
            fail(error)
            throw MeetingTapeError.failure("\(error); recovery materials: \(report?.recoveryPath ?? "unknown")")
        }
    }

    private func publish() {
        statusLock.lock()
        published = report
        statusLock.unlock()
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.resume() }
        })
    }

    private func suspend() {
        guard let state = report?.state, state == .recording || state == .interrupted, sleepingSince == nil else { return }
        do {
            statusLock.lock()
            preservationWatch = .sleeping
            statusLock.unlock()
            try ingest()
            capture.stop()
            try ingest()
            let now = clock.elapsed
            try render(until: Int64(now * 48_000) / 480 * 480, health: capture.health())
            sleepingSince = now
            bothUnavailableSince = nil
            report?.state = .interrupted
            report?.elapsedSeconds = now
            report?.systemAvailable = false
            report?.microphoneAvailable = false
            try checkpoint()
            publish()
        } catch { fail(error) }
    }

    private func resume() {
        guard let beginning = sleepingSince, report?.state == .interrupted else { return }
        let now = clock.elapsed
        addInterval(start: beginning, end: now, source: nil, reason: "system sleep", degraded: false)
        nextFrame = Int64(now * 48_000) / 480 * 480
        timeline = CaptureTimeline()
        clock.beginEpoch()
        speech.reset()
        sleepingSince = nil
        statusLock.lock()
        preservationWatch = .awake(lastCommit: ProcessInfo.processInfo.systemUptime)
        statusLock.unlock()
        do {
            try capture.start(requireBothSources: false)
            let health = capture.health()
            report?.systemAvailable = health.systemAvailable
            report?.microphoneAvailable = health.microphoneAvailable
            report?.state = health.systemAvailable && health.microphoneAvailable ? .recording : .interrupted
            report?.elapsedSeconds = now
            try checkpoint()
            publish()
        } catch { fail(error) }
    }

    private func acquirePowerAssertion() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                   "MeetingTape recording" as CFString, &assertion)
    }

    private func releaseResources() {
        statusLock.lock()
        preservationWatch = .stopped
        statusLock.unlock()
        watchdog?.cancel()
        watchdog = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    static func validateOutput(_ path: String) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
            throw MeetingTapeError.outDirectoryDoesNotExist(path)
        }
        guard directory.boolValue else { throw MeetingTapeError.outPathNotADirectory(path) }
        guard FileManager.default.isWritableFile(atPath: path) else { throw MeetingTapeError.outDirectoryNotWritable(path) }
    }
}

public enum RecordingRecovery {
    public static func recover(directory: String, outputDirectory: String) throws -> SessionSnapshot {
        try RecordingSession.validateOutput(outputDirectory)
        return try RecoveryStore.recover(directory: URL(fileURLWithPath: directory), outputDirectory: URL(fileURLWithPath: outputDirectory))
    }
}
