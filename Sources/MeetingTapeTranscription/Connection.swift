import AVFoundation
import Foundation

public enum TranscriptionConnection {
    public static func test() throws {
        let credential = try TranscriptionCredentials.load()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-connection-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000) else { throw TranscriptionFailure("无法生成测试音频。") }
        buffer.frameLength = 16000
        if let samples = buffer.int16ChannelData?[0] { samples.initialize(repeating: 0, count: 16000) }
        do { let file = try AVAudioFile(forWriting: temporary, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true); try file.write(from: buffer) }
        let response = try Doubao.request("submit", id: UUID().uuidString.lowercased(), credential: credential, body: Doubao.payload(temporary))
        guard response.code == "20000000" else { throw TranscriptionFailure("豆包连接验证失败（\(response.code)）。") }
    }
}
