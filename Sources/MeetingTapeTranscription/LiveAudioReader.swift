import AVFoundation
import Darwin
import Foundation
import MeetingTapeCore

final class LiveAudioReader {
    private struct Span: Decodable {
        var startFrame: Int64
        var frameCount: Int64
    }
    private struct Manifest: Decodable {
        var version: Int
        var sampleRate: Int
        var channels: Int
        var audioFile: String
        var audioFrames: Int64
        var timelineFrames: Int64
        var spans: [Span]
        var snapshot: SessionSnapshot
    }

    let sessionID: String
    private let source: TranscriptSource
    private let directory: URL
    private var descriptor: Int32 = -1
    private var finalFile: AVAudioFile?
    private(set) var cursor: Int64
    private(set) var committedFrame: Int64 = 0
    private(set) var available = true
    private(set) var state: RecordingState = .recording
    var sealed: Bool { [.finalizing, .completed, .failed].contains(state) }

    init(snapshot: SessionSnapshot, startFrame: Int64, source: TranscriptSource = .merged) {
        sessionID = snapshot.sessionID
        self.source = source
        directory = URL(fileURLWithPath: snapshot.recoveryPath)
        cursor = startFrame
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func readCommitted() throws -> [Float]? {
        let path = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else { available = false; return nil }
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            available = false; return nil
        }
        guard data.count <= 8 * 1_048_576 else { throw TranscriptionFailure("录音时间轴过大，实时字幕已停止。") }
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.version == 1, value.sampleRate == 48000, value.channels == 2, value.audioFile == "audio.caf",
              value.snapshot.sessionID == sessionID, value.audioFrames >= 0,
              value.timelineFrames >= committedFrame, value.timelineFrames <= 48_000 * 3600 * 24,
              value.spans.count <= 100_000 else { throw TranscriptionFailure("录音时间轴不兼容，实时字幕已停止。") }
        var previous: Int64 = 0, total: Int64 = 0
        for span in value.spans {
            guard span.startFrame >= previous, span.frameCount > 0,
                  span.startFrame <= value.timelineFrames, span.frameCount <= value.timelineFrames - span.startFrame,
                  total <= value.audioFrames, span.frameCount <= value.audioFrames - total else {
                throw TranscriptionFailure("录音片段时间轴无效，实时字幕已停止。")
            }
            previous = span.startFrame + span.frameCount; total += span.frameCount
        }
        guard total == value.audioFrames else { throw TranscriptionFailure("录音片段长度不匹配，实时字幕已停止。") }
        available = true; committedFrame = value.timelineFrames; state = value.snapshot.state
        guard cursor < committedFrame else { return nil }
        guard committedFrame - cursor <= 48_000 * 10 else { throw TranscriptionFailure("字幕连接过慢，录音继续。请重新连接字幕。") }
        if descriptor < 0 {
            descriptor = open(directory.appendingPathComponent("audio.caf").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw TranscriptionFailure("无法读取已提交录音，录音继续。") }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              value.audioFrames <= (Int64.max - 68) / 8,
              info.st_size >= 68 + value.audioFrames * 8 else { throw TranscriptionFailure("已提交音频长度不足，实时字幕已停止。") }
        let end = min(cursor + 9600, committedFrame)
        var samples = [Float](repeating: 0, count: Int(end - cursor))
        var offset: Int64 = 0
        for span in value.spans {
            let beginning = max(cursor, span.startFrame)
            let finish = min(end, span.startFrame + span.frameCount)
            if beginning < finish {
                let count = Int(finish - beginning)
                let bytes = try read(offset: 68 + (offset + beginning - span.startFrame) * 8, count: count * 8)
                try bytes.withUnsafeBytes { raw in
                    for index in 0..<count {
                        let left = raw.loadUnaligned(fromByteOffset: index * 8, as: Float.self)
                        let right = raw.loadUnaligned(fromByteOffset: index * 8 + 4, as: Float.self)
                        guard left.isFinite, right.isFinite else { throw TranscriptionFailure("录音包含无效样本，实时字幕已停止。") }
                        samples[Int(beginning - cursor) + index] = selectedSample(left: left, right: right)
                    }
                }
            }
            offset += span.frameCount
            if span.startFrame + span.frameCount >= end { break }
        }
        cursor = end
        return samples
    }

    func readFinal(_ snapshot: SessionSnapshot) throws -> [Float]? {
        guard snapshot.sessionID == sessionID, let path = snapshot.outputPath else { return try readCommitted() }
        let target = Int64((snapshot.elapsedSeconds * 48000).rounded())
        guard cursor < target else { return nil }
        if finalFile == nil { finalFile = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: true) }
        guard let file = finalFile, file.processingFormat.sampleRate == 48000, file.processingFormat.channelCount == 2,
              file.length >= target - 4096 else { throw TranscriptionFailure("无法读取录音尾部，已保留现有字幕。") }
        let count = Int(min(9600, target - cursor))
        var selected = [Float](repeating: 0, count: count)
        file.framePosition = min(cursor, file.length)
        let readable = AVAudioFrameCount(min(Int64(count), file.length - file.framePosition))
        if readable > 0 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readable) else { throw TranscriptionFailure("无法分配字幕音频缓冲。") }
            try file.read(into: buffer, frameCount: readable)
            guard let interleaved = buffer.floatChannelData?[0], buffer.frameLength == readable else { throw TranscriptionFailure("录音尾部读取不完整。") }
            for index in 0..<Int(readable) {
                selected[index] = selectedSample(left: interleaved[index * 2], right: interleaved[index * 2 + 1])
            }
        }
        cursor += Int64(count)
        return selected
    }

    private func selectedSample(left: Float, right: Float) -> Float {
        let value = source.channel.map { $0 == 0 ? left : right } ?? (left * 0.5 + right * 0.5)
        return max(-1, min(1, value))
    }

    private func read(offset: Int64, count: Int) throws -> Data {
        var value = Data(count: count)
        try value.withUnsafeMutableBytes { bytes in
            var copied = 0
            while copied < count {
                let result = pread(descriptor, bytes.baseAddress!.advanced(by: copied), count - copied, off_t(offset + Int64(copied)))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw TranscriptionFailure("无法读取已提交音频，已保留现有字幕。") }
                copied += result
            }
        }
        return value
    }
}

final class LivePCMConverter {
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter

    init() throws {
        guard let value = AVAudioConverter(from: source, to: target) else { throw TranscriptionFailure("无法创建实时字幕音频转换器。") }
        converter = value
    }

    func convert(_ samples: [Float], final: Bool = false) throws -> Data {
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count / 3 + 256)) else { throw TranscriptionFailure("无法分配字幕音频缓冲。") }
        input.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty { samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) } }
        let feed = LiveConversionInput(buffer: input, final: final)
        var bytes = Data()
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in feed.next(state) }
            if error != nil { throw TranscriptionFailure("实时字幕音频转换失败。") }
            if output.frameLength > 0, let pointer = output.int16ChannelData?[0] { bytes.append(Data(bytes: pointer, count: Int(output.frameLength) * 2)) }
            if status != .haveData { break }
        }
        return bytes
    }
}

private final class LiveConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let final: Bool
    var consumed = false
    init(buffer: AVAudioPCMBuffer, final: Bool) { self.buffer = buffer; self.final = final }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if consumed || buffer.frameLength == 0 { state.pointee = final ? .endOfStream : .noDataNow; return nil }
        consumed = true; state.pointee = .haveData; return buffer
    }
}
