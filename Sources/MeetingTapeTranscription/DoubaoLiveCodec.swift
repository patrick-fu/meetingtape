import Foundation
import zlib

struct DoubaoLiveFrame: Sendable {
    var segments: [LiveCaptionSegment]
    var hasResult: Bool
    var final: Bool
}

enum DoubaoLiveCodec {
    static func packet(_ bytes: Data, audio: Bool, final: Bool = false) -> Data {
        var value = Data([0x11, audio ? (final ? 0x22 : 0x20) : 0x10, audio ? 0 : 0x10, 0])
        var size = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &size) { value.append(contentsOf: $0) }
        value.append(bytes)
        return value
    }

    static func decode(_ data: Data, origin: Double) throws -> DoubaoLiveFrame {
        guard data.count >= 8, data.count <= 8 * 1_048_576, data[0] >> 4 == 1 else { throw invalid() }
        let header = Int(data[0] & 15) * 4
        guard header >= 4, header <= data.count - 4 else { throw invalid() }
        let type = data[1] >> 4, flags = data[1] & 15
        var offset = header
        if type == 15 {
            guard offset + 8 <= data.count else { throw invalid() }
            let code = number(data, at: offset)
            throw TranscriptionFailure("豆包实时字幕返回错误（\(code)），录音继续。")
        }
        guard type == 9 else { throw invalid() }
        if flags & 1 != 0 { offset += 4 }
        guard offset + 4 <= data.count else { throw invalid() }
        let count = Int(number(data, at: offset)); offset += 4
        guard count == data.count - offset, data[2] >> 4 == 1 else { throw invalid() }
        var payload = data.subdata(in: offset..<data.count)
        switch data[2] & 15 {
        case 0: break
        case 1: payload = try inflate(payload)
        default: throw invalid()
        }
        guard let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw invalid() }
        let isFinal = flags & 2 != 0
        let result = body["result"] as? [String: Any] ?? [:]
        let raw = result["utterances"] as? [[String: Any]] ?? []
        guard raw.count <= 20_000 else { throw TranscriptionFailure("实时字幕已达到单次文本上限，录音继续。") }
        var segments: [LiveCaptionSegment] = []
        var precedingEnd = 0.0
        for utterance in raw {
            let words = utterance["words"] as? [[String: Any]] ?? []
            let start = utterance["start_time"] as? Double ?? words.first?["start_time"] as? Double ?? precedingEnd
            let end = utterance["end_time"] as? Double ?? words.last?["end_time"] as? Double ?? start
            guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= 86_400_000,
                  let text = utterance["text"] as? String, text.utf8.count <= 65536 else { throw invalid() }
            precedingEnd = end
            if !text.isEmpty {
                segments.append(LiveCaptionSegment(id: "\(Int64((origin * 48000).rounded()))-\(Int64(start))",
                    start: origin + start / 1000, end: origin + end / 1000, text: text,
                    final: utterance["definite"] as? Bool ?? isFinal))
            }
        }
        if raw.isEmpty, let text = result["text"] as? String, !text.isEmpty {
            guard text.utf8.count <= 1_048_576 else { throw invalid() }
            let audio = body["audio_info"] as? [String: Any]
            let duration = audio?["duration"] as? Double ?? 0
            guard duration.isFinite, duration >= 0, duration <= 86_400_000 else { throw invalid() }
            segments = [LiveCaptionSegment(id: "\(Int64((origin * 48000).rounded()))-fallback", start: origin,
                end: origin + duration / 1000, text: text, final: isFinal)]
        }
        return DoubaoLiveFrame(segments: segments, hasResult: result["text"] != nil || result["utterances"] != nil, final: isFinal)
    }

    private static func number(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func inflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            while true {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let status = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw invalid() }
                result.append(contentsOf: bytes.prefix(bytes.count - Int(stream.avail_out)))
                guard result.count <= 8 * 1_048_576 else { throw invalid() }
                if status == Z_STREAM_END { return result }
                guard stream.avail_in > 0 || stream.avail_out == 0 else { throw invalid() }
            }
        }
    }

    private static func invalid() -> TranscriptionFailure { TranscriptionFailure("豆包实时字幕响应格式无效，录音继续。") }
}
