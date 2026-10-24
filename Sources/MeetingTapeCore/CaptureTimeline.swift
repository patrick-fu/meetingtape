import AVFoundation
import Darwin

struct SessionClock {
    private let ticksToSeconds: Double
    private let beginning: UInt64
    private var absoluteAnchor: UInt64
    private var continuousAnchor: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        ticksToSeconds = Double(info.numer) / Double(info.denom) / 1_000_000_000
        absoluteAnchor = mach_absolute_time()
        continuousAnchor = mach_continuous_time()
        beginning = continuousAnchor
    }

    var elapsed: Double {
        Double(mach_continuous_time() - beginning) * ticksToSeconds
    }

    mutating func beginEpoch() {
        absoluteAnchor = mach_absolute_time()
        continuousAnchor = mach_continuous_time()
    }

    func frame(for hostTime: UInt64) -> Int64 {
        let epochOffset = Double(continuousAnchor - beginning) * ticksToSeconds
        let delta = hostTime >= absoluteAnchor
            ? Double(hostTime - absoluteAnchor) * ticksToSeconds
            : -Double(absoluteAnchor - hostTime) * ticksToSeconds
        return Int64(((epochOffset + delta) * 48_000).rounded())
    }
}

private struct TimelineChunk {
    let start: Int64
    let channels: [[Float]]
    var count: Int { channels[0].count }
    var end: Int64 { start + Int64(count) }
}

private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    var wasSupplied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return supplied
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

private final class TimelineTrack {
    private var chunks: [TimelineChunk] = []
    private var converter: AVAudioConverter?
    private var formatKey = ""
    private var previousEnd: Int64?
    private var pendingFrames = 0.0
    private var lastInput: ConverterInput?

    func insert(_ packet: CapturedAudio, frame: Int64) throws {
        guard packet.channels == 1 || packet.channels == 2,
              packet.sampleRate.isFinite, packet.sampleRate >= 8_000, packet.sampleRate <= 192_000,
              !packet.samples.isEmpty, packet.samples.count % packet.channels == 0,
              packet.samples.allSatisfy(\.isFinite) else {
            throw MeetingTapeError.failure("invalid captured audio format or samples")
        }
        let count = packet.samples.count / packet.channels
        let key = "\(packet.generation):\(packet.sampleRate):\(packet.channels)"
        let discontinuity = previousEnd.map { abs(Double(frame) - pendingFrames - Double($0)) > 48 } ?? false
        if key != formatKey || discontinuity {
            try flush()
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: packet.sampleRate,
                                      channels: AVAudioChannelCount(packet.channels), interleaved: false)!
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: AVAudioChannelCount(packet.channels), interleaved: false)!
            guard let made = AVAudioConverter(from: input, to: output) else {
                throw MeetingTapeError.failure("cannot convert captured audio to 48000 Hz")
            }
            made.primeMethod = .normal
            made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
            formatKey = key
            previousEnd = nil
        }
        if previousEnd == nil { previousEnd = frame }
        let converter = converter!
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let inputChannels = input.floatChannelData else {
            throw MeetingTapeError.failure("cannot allocate audio conversion buffer")
        }
        input.frameLength = AVAudioFrameCount(count)
        for channel in 0..<packet.channels {
            for index in 0..<count {
                inputChannels[channel][index] = packet.samples[index * packet.channels + channel]
            }
        }
        let capacity = AVAudioFrameCount(ceil(Double(count) * 48_000 / packet.sampleRate) + 128)
        let inputSource = ConverterInput(input)
        defer { if inputSource.wasSupplied { lastInput = inputSource } }
        pendingFrames += Double(count) * 48_000 / packet.sampleRate
        for _ in 0..<64 {
            let result = try convert(input: inputSource, capacity: capacity)
            if result == .inputRanDry {
                guard inputSource.wasSupplied else {
                    throw MeetingTapeError.failure("audio converter did not consume captured input")
                }
                return
            }
            if result == .endOfStream {
                throw MeetingTapeError.failure("audio converter ended before capture finished")
            }
        }
        throw MeetingTapeError.failure("audio converter exceeded its bounded conversion budget")
    }

    private func convert(input: ConverterInput?, capacity: AVAudioFrameCount) throws -> AVAudioConverterOutputStatus {
        let converter = converter!
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw MeetingTapeError.failure("cannot allocate converted audio buffer")
        }
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if let input { return input.next(status) }
            status.pointee = .endOfStream
            return nil
        }
        guard result != .error, error == nil, let data = output.floatChannelData else {
            throw MeetingTapeError.failure("audio sample-rate conversion failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let length = Int(output.frameLength)
        if length > 0 {
            let values = (0..<Int(output.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: length)) }
            chunks.append(TimelineChunk(start: previousEnd!, channels: values))
            previousEnd! += Int64(length)
            pendingFrames -= Double(length)
            guard chunks.reduce(0, { $0 + $1.count }) <= 96_000 else {
                throw MeetingTapeError.failure("audio alignment queue exceeded two seconds")
            }
        }
        return result
    }

    func flush() throws {
        guard converter != nil else { return }
        for _ in 0..<64 {
            if try convert(input: nil, capacity: 8192) == .endOfStream {
                converter = nil
                formatKey = ""
                previousEnd = nil
                pendingFrames = 0
                lastInput = nil
                return
            }
        }
        throw MeetingTapeError.failure("audio converter did not finish within its bounded flush budget")
    }

    func prepare(until frame: Int64) throws {
        if let previousEnd, frame > previousEnd { try flush() }
    }

    func render(at frame: Int64, count: Int) -> (left: [Float], right: [Float], complete: Bool, present: Bool) {
        let end = frame + Int64(count)
        chunks.removeAll { $0.end <= frame }
        var left = [Float](repeating: 0, count: count)
        var right = left
        var covered = [Bool](repeating: false, count: count)
        for chunk in chunks where chunk.start < end {
            let begin = max(frame, chunk.start)
            let limit = min(end, chunk.end)
            guard limit > begin else { continue }
            let sourceOffset = Int(begin - chunk.start)
            let targetOffset = Int(begin - frame)
            for index in 0..<Int(limit - begin) {
                left[targetOffset + index] = chunk.channels[0][sourceOffset + index]
                right[targetOffset + index] = chunk.channels.count == 2
                    ? chunk.channels[1][sourceOffset + index] : chunk.channels[0][sourceOffset + index]
                covered[targetOffset + index] = true
            }
        }
        return (left, right, covered.allSatisfy { $0 }, covered.contains(true))
    }
}

final class CaptureTimeline {
    private let system = TimelineTrack()
    private let microphone = TimelineTrack()

    func insert(_ packet: CapturedAudio, frame: Int64) throws {
        try (packet.source == .system ? system : microphone).insert(packet, frame: frame)
    }

    func prepare(until frame: Int64) throws {
        try system.prepare(until: frame)
        try microphone.prepare(until: frame)
    }

    func flush() throws {
        try system.flush()
        try microphone.flush()
    }

    func render(at frame: Int64, count: Int) -> (systemLeft: [Float], systemRight: [Float], microphone: [Float], hasSystem: Bool, hasMicrophone: Bool, hasAnyAudio: Bool, hasAnyMicrophone: Bool) {
        let left = system.render(at: frame, count: count)
        let right = microphone.render(at: frame, count: count)
        return (left.left, left.right, right.left, left.complete, right.complete, left.present || right.present, right.present)
    }
}
