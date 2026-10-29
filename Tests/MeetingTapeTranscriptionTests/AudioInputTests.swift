import AVFoundation
import Foundation
import MeetingTapeCore
import Testing
@testable import MeetingTapeTranscription

@Test func transcriptionInputSelectsSeparateChannelsAndKeepsMergedAverage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-audio-input-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("stereo.caf")
    try writePCM(input, channels: [0.75, -0.25])
    let original = try Data(contentsOf: input)
    for (source, expected) in [(TranscriptSource.system, 0.75), (.microphone, -0.25), (.merged, 0.25)] {
        let destination = directory.appendingPathComponent("\(source.rawValue).wav")
        try TranscriptionAudio.prepare(input, destination: destination, start: 0, duration: 1, source: source)
        #expect(abs(try meanSample(destination) - expected) < 0.02)
    }
    #expect(try Data(contentsOf: input) == original)
}

@Test func transcriptionInputIdentifiesOnlyDeclaredNativeStereoRecordings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetingtape-native-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionID = UUID().uuidString.lowercased()
    let native = directory.appendingPathComponent("meetingtape-\(sessionID)-\(UUID().uuidString.lowercased()).m4a")
    try writeM4A(native, channels: [0.2, -0.2])
    try writeCompletedSnapshot(for: native, sessionID: sessionID)
    let nativeDescription = try TranscriptionAudio.inspect(native)
    #expect(nativeDescription.channelCount == 2)
    #expect(nativeDescription.nativeSessionID == sessionID)
    #expect(nativeDescription.duration > 0)

    let externalStereo = directory.appendingPathComponent("external-stereo.m4a")
    try writeM4A(externalStereo, channels: [0.2, -0.2])
    #expect(try TranscriptionAudio.inspect(externalStereo).nativeSessionID == nil)

    let monoID = UUID().uuidString.lowercased()
    let mono = directory.appendingPathComponent("meetingtape-\(monoID)-\(UUID().uuidString.lowercased()).m4a")
    try writeM4A(mono, channels: [0.2])
    try writeCompletedSnapshot(for: mono, sessionID: monoID)
    let monoDescription = try TranscriptionAudio.inspect(mono)
    #expect(monoDescription.channelCount == 1)
    #expect(monoDescription.nativeSessionID == nil)
    #expect(throws: (any Error).self) {
        try TranscriptionAudio.prepare(mono, destination: directory.appendingPathComponent("mono.wav"),
                                      start: 0, duration: 1, source: .system)
    }
}

private func writePCM(_ url: URL, channels values: [Float]) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                               channels: AVAudioChannelCount(values.count), interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    buffer.frameLength = buffer.frameCapacity
    for channel in values.indices {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = values[channel] }
    }
    try file.write(from: buffer)
}

private func writeM4A(_ url: URL, channels values: [Float]) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: values.count,
        AVEncoderBitRateKey: 128_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    buffer.frameLength = buffer.frameCapacity
    for channel in values.indices {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = values[channel] }
    }
    try file.write(from: buffer)
}

private func writeCompletedSnapshot(for audio: URL, sessionID: String) throws {
    var snapshot = SessionSnapshot(sessionID: sessionID, recoveryPath: "/temporary/recovery")
    snapshot.state = .completed
    snapshot.outputPath = audio.path
    try JSONEncoder().encode(snapshot).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
}

private func meanSample(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = buffer.floatChannelData![0]
    return (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1]) } / Double(buffer.frameLength)
}
