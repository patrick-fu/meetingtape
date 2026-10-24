import CaptureSupport
import Foundation

struct CapturedAudio {
    let source: AudioSource
    let hostTime: UInt64
    let sampleRate: Double
    let channels: Int
    let generation: UInt64
    let samples: [Float]
}

struct CaptureHealth {
    let systemAvailable: Bool
    let microphoneAvailable: Bool
    let systemReason: String?
    let microphoneReason: String?
    let fatalError: String?
}

private struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

final class AudioCapture {
    private struct SourceCapture {
        let source: AudioSource
        var stream: MTStreamRef?
        var reason: String? = "Capture is stopped"
        var retryAfter = 0.0
    }

    private var system = SourceCapture(source: .system)
    private var microphone = SourceCapture(source: .microphone)
    private var generation: UInt64 = 0
    private var running = false
    private var latchedFatal: String?
    private var pending: [CapturedAudio] = []

    init() {}

    deinit {
        stop()
    }

    func start() throws {
        guard !running else { return }
        if let latchedFatal { throw CaptureError(description: latchedFatal) }
        pending.removeAll(keepingCapacity: false)
        running = true
        do {
            try open(&system)
            try open(&microphone)
            latchCallbackFailure(system)
            latchCallbackFailure(microphone)
            if let latchedFatal { throw CaptureError(description: latchedFatal) }
        } catch {
            stop()
            throw error
        }
    }

    func drain() -> [CapturedAudio] {
        var chunks = pending
        pending.removeAll(keepingCapacity: false)
        appendDrained(system, to: &chunks)
        appendDrained(microphone, to: &chunks)
        latchCallbackFailure(system)
        latchCallbackFailure(microphone)
        return chunks
    }

    func health() -> CaptureHealth {
        latchCallbackFailure(system)
        latchCallbackFailure(microphone)
        let systemReason = unavailableReason(system)
        let microphoneReason = unavailableReason(microphone)
        return CaptureHealth(
            systemAvailable: systemReason == nil,
            microphoneAvailable: microphoneReason == nil,
            systemReason: systemReason,
            microphoneReason: microphoneReason,
            fatalError: latchedFatal
        )
    }

    func refreshIfNeeded() throws {
        guard running else { return }
        latchCallbackFailure(system)
        latchCallbackFailure(microphone)
        if let latchedFatal { throw CaptureError(description: latchedFatal) }
        refresh(&system)
        if let latchedFatal { throw CaptureError(description: latchedFatal) }
        refresh(&microphone)
        if let latchedFatal { throw CaptureError(description: latchedFatal) }
    }

    func stop() {
        guard running else { return }
        running = false
        if let stream = system.stream { MTStreamQuiesce(stream) }
        if let stream = microphone.stream { MTStreamQuiesce(stream) }
        latchCallbackFailure(system)
        latchCallbackFailure(microphone)
        close(&system, retainQueuedAudio: true)
        close(&microphone, retainQueuedAudio: true)
    }

    private func open(_ capture: inout SourceCapture) throws {
        generation += 1
        var cleanupFailed = false
        var message = [CChar](repeating: 0, count: 1024)
        let nativeSource = capture.source == .system ? MTCaptureSystem : MTCaptureMicrophone
        let stream = MTStreamCreate(nativeSource, generation, &cleanupFailed, &message, message.count)
        guard let stream else {
            let reason = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            capture.reason = reason
            capture.retryAfter = ProcessInfo.processInfo.systemUptime + 1
            if cleanupFailed { latchedFatal = latchedFatal ?? reason }
            throw CaptureError(description: reason)
        }
        capture.stream = stream
        capture.reason = nil
        capture.retryAfter = 0
    }

    private func close(_ capture: inout SourceCapture, retainQueuedAudio: Bool) {
        guard let stream = capture.stream else { return }
        var message = [CChar](repeating: 0, count: 1024)
        if !MTStreamStop(stream, &message, message.count) {
            latchedFatal = latchedFatal ?? String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        latchCallbackFailure(capture)
        if retainQueuedAudio { appendDrained(capture, to: &pending) }
        MTStreamDestroy(stream)
        capture.stream = nil
        capture.reason = "Capture is stopped"
    }

    private func refresh(_ capture: inout SourceCapture) {
        if let stream = capture.stream {
            let status = MTStreamPoll(stream)
            guard MTStreamNeedsRefresh(stream) || (capture.source == .microphone && status.secondsSinceCallback > 3) else { return }
            close(&capture, retainQueuedAudio: false)
            if latchedFatal != nil { return }
        }
        guard ProcessInfo.processInfo.systemUptime >= capture.retryAfter else { return }
        do {
            try open(&capture)
        } catch {
            capture.reason = String(describing: error)
        }
    }

    private func appendDrained(_ capture: SourceCapture, to chunks: inout [CapturedAudio]) {
        guard let stream = capture.stream else { return }
        var info = MTChunkInfo()
        while MTStreamPeek(stream, &info) {
            let count = Int(info.frames) * Int(info.channels)
            var samples = [Float](repeating: 0, count: count)
            let read = samples.withUnsafeMutableBufferPointer {
                MTStreamRead(stream, $0.baseAddress, UInt32(count), &info)
            }
            guard read else { break }
            chunks.append(CapturedAudio(
                source: capture.source,
                hostTime: info.hostTime,
                sampleRate: info.sampleRate,
                channels: Int(info.channels),
                generation: info.generation,
                samples: samples
            ))
        }
    }

    private func unavailableReason(_ capture: SourceCapture) -> String? {
        guard let stream = capture.stream else { return capture.reason }
        let status = MTStreamPoll(stream)
        if status.callbackError != MTCaptureNoError {
            return callbackFailure(status.callbackError, source: capture.source)
        }
        if status.configurationChanged { return "Audio device configuration changed" }
        if capture.source == .microphone {
            if status.secondsSinceCallback > 3 { return "Microphone callbacks have stopped" }
            if !status.receivedAudio { return "Waiting for the first microphone callback" }
        }
        return nil
    }

    private func latchCallbackFailure(_ capture: SourceCapture) {
        guard latchedFatal == nil, let stream = capture.stream else { return }
        let error = MTStreamPoll(stream).callbackError
        if error != MTCaptureNoError {
            latchedFatal = callbackFailure(error, source: capture.source)
        }
    }

    private func callbackFailure(_ error: MTCaptureCallbackError, source: AudioSource) -> String {
        let reason: String
        switch error {
        case MTCaptureOverflow: reason = "The one-second audio queue overflowed"
        case MTCaptureInvalidLayout: reason = "The audio callback supplied an unsupported layout"
        case MTCaptureInvalidTimestamp: reason = "The audio callback supplied an invalid or nonmonotonic host timestamp"
        case MTCaptureNonfiniteSample: reason = "The audio callback supplied a nonfinite sample"
        case MTCaptureConcurrentCallback: reason = "Audio callbacks overlapped for a single source"
        default: reason = "The audio callback failed"
        }
        return "\(source.rawValue): \(reason)"
    }
}
