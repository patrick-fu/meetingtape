import AVFoundation
import Foundation

enum TranscriptionAudio {
    static func duration(_ path: URL) throws -> Double {
        let file = try AVAudioFile(forReading: path)
        let value = Double(file.length) / file.processingFormat.sampleRate
        guard value.isFinite, value > 0, value <= 5 * 3600 else { throw TranscriptionFailure("转写支持五小时以内的有效录音。") }
        return value
    }

    static func prepare(_ source: URL, destination: URL, start: Double, duration: Double) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: target) else { throw TranscriptionFailure("无法转换转写音频。") }
        let output = try AVAudioFile(forWriting: destination, settings: target.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        file.framePosition = AVAudioFramePosition(start * format.sampleRate)
        var remaining = min(file.length - file.framePosition, AVAudioFramePosition(duration * format.sampleRate))
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, 48000))
            guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: count) else { throw TranscriptionFailure("音频转换内存不足。") }
            try file.read(into: input, frameCount: count)
            guard input.frameLength > 0, let channels = input.floatChannelData, let samples = mixed.floatChannelData?[0] else { break }
            mixed.frameLength = input.frameLength
            for frame in 0..<Int(input.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(format.channelCount) { value += channels[channel][frame] / Float(format.channelCount) }
                samples[frame] = value
            }
            remaining -= AVAudioFramePosition(input.frameLength)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16000 / format.sampleRate) + 128) else { throw TranscriptionFailure("音频转换内存不足。") }
            let feed = ConversionInput(mixed, final: remaining == 0)
            while true {
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, status in feed.next(status) }
                if let error { throw error }
                if buffer.frameLength > 0 { try output.write(from: buffer) }
                if status != .haveData { break }
            }
        }
    }
}

private final class ConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let final: Bool
    private var consumed = false
    init(_ buffer: AVAudioPCMBuffer, final: Bool) { self.buffer = buffer; self.final = final }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if consumed { status.pointee = final ? .endOfStream : .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return buffer
    }
}
