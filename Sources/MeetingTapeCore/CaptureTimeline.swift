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

    func insert(_ packet: CapturedAudio, frame: Int64) throws {
        guard packet.channels == 1 || packet.channels == 2,
              packet.sampleRate.isFinite, packet.sampleRate >= 8_000, packet.sampleRate <= 192_000,
              !packet.samples.isEmpty, packet.samples.count % packet.channels == 0,
              packet.samples.allSatisfy(\.isFinite) else {
            throw MeetingTapeError.failure("invalid captured audio format or samples")
        }
        let count = packet.samples.count / packet.channels
        let key = "\(packet.generation):\(packet.sampleRate):\(packet.channels)"
        if key != formatKey {
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: packet.sampleRate,
                                      channels: AVAudioChannelCount(packet.channels), interleaved: false)!
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: AVAudioChannelCount(packet.channels), interleaved: false)!
            guard let made = AVAudioConverter(from: input, to: output) else {
                throw MeetingTapeError.failure("cannot convert captured audio to 48000 Hz")
            }
            made.primeMethod = .none
            made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
            formatKey = key
            previousEnd = nil
        }
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
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw MeetingTapeError.failure("cannot allocate converted audio buffer")
        }
        let inputSource = ConverterInput(input)
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            inputSource.next(status)
        }
        guard result != .error, error == nil, let data = output.floatChannelData else {
            throw MeetingTapeError.failure("audio sample-rate conversion failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let length = Int(output.frameLength)
        guard length > 0 else { return }
        var start = frame
        if let previousEnd, abs(start - previousEnd) <= 48 { start = previousEnd }
        let values = (0..<packet.channels).map { Array(UnsafeBufferPointer(start: data[$0], count: length)) }
        chunks.append(TimelineChunk(start: start, channels: values))
        previousEnd = start + Int64(length)
        guard chunks.reduce(0, { $0 + $1.count }) <= 96_000 else {
            throw MeetingTapeError.failure("audio alignment queue exceeded two seconds")
        }
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

    func render(at frame: Int64, count: Int) -> (systemLeft: [Float], systemRight: [Float], microphone: [Float], hasSystem: Bool, hasMicrophone: Bool, hasAnyAudio: Bool, hasAnyMicrophone: Bool) {
        let left = system.render(at: frame, count: count)
        let right = microphone.render(at: frame, count: count)
        return (left.left, left.right, right.left, left.complete, right.complete, left.present || right.present, right.present)
    }
}
