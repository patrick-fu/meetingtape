import AVFoundation
import Foundation
import Testing
@testable import MeetingTapeCore

@Test func recoveryUsesCommittedTimelineAndRawSamples() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("session.recovery")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let existing = root.appendingPathComponent("existing.m4a")
    try Data("existing recording".utf8).write(to: existing)
    var snapshot = SessionSnapshot(recoveryPath: directory.path)
    let stereo = (0..<48_000).flatMap { frame -> [Float] in
        let time = Double(frame) / 48_000
        return [Float(0.15 * sin(2 * .pi * 440 * time)), Float(0.12 * sin(2 * .pi * 880 * time))]
    }
    do {
        let store = try RecoveryStore(directory: directory, keepRaw: true, snapshot: snapshot)
        try store.append(stereo: stereo, rawMicrophone: Array(repeating: 0.125, count: 48_000), at: 0)
        try store.append(stereo: stereo, rawMicrophone: Array(repeating: 0.25, count: 48_000), at: 144_000)
        snapshot.elapsedSeconds = 5
        #expect(try store.checkpoint(snapshot) == 240_000)
        do {
            _ = try RecoveryStore.recover(directory: directory, outputDirectory: root)
            Issue.record("Recovery accepted a live writer")
        } catch {
            #expect(String(describing: error).contains("active writer"))
        }
        try store.append(stereo: stereo, rawMicrophone: Array(repeating: 0.75, count: 48_000), at: 240_000)
    }
    let result = try RecoveryStore.recover(directory: directory, outputDirectory: root)
    #expect(result.state == .completed)
    #expect(result.elapsedSeconds == 5)
    #expect(result.committedSeconds == 5)
    #expect(try Data(contentsOf: existing) == Data("existing recording".utf8))
    #expect(!manager.fileExists(atPath: directory.path))
    let audioURL = URL(fileURLWithPath: try #require(result.outputPath))
    let metadata = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: audioURL.deletingPathExtension().appendingPathExtension("json")))
    #expect(metadata.outputPath == result.outputPath)
    #expect(metadata.rawOutputPath == result.rawOutputPath)
    #expect(metadata.state == .completed)
    let audio = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: true)
    #expect(audio.processingFormat.sampleRate == 48_000)
    #expect(audio.processingFormat.channelCount == 2)
    #expect(abs(audio.length - 240_000) < 4_096)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48_000))
    audio.framePosition = 72_000
    try audio.read(into: buffer, frameCount: 48_000)
    let samples = try #require(buffer.floatChannelData?[0])
    #expect((0..<96_000).allSatisfy { abs(samples[$0]) < 0.0001 })
    let rawURL = URL(fileURLWithPath: try #require(result.rawOutputPath))
    let raw = try AVAudioFile(forReading: rawURL, commonFormat: .pcmFormatFloat32, interleaved: true)
    #expect(raw.length == 240_000)
    #expect(raw.processingFormat.channelCount == 1)
    let rawBuffer = try #require(AVAudioPCMBuffer(pcmFormat: raw.processingFormat, frameCapacity: 240_000))
    try raw.read(into: rawBuffer)
    let rawSamples = try #require(rawBuffer.floatChannelData?[0])
    #expect(rawSamples[24_000] == 0.125)
    #expect(rawSamples[96_000] == 0)
    #expect(rawSamples[168_000] == 0.25)
    #expect(rawSamples[216_000] == 0)
}

@Test func recoveryRefusesTruncatedCommittedExtentAndKeepsMaterials() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("session.recovery")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    var snapshot = SessionSnapshot(recoveryPath: directory.path)
    do {
        let store = try RecoveryStore(directory: directory, keepRaw: false, snapshot: snapshot)
        try store.append(stereo: Array(repeating: 0.1, count: 960), rawMicrophone: nil, at: 0)
        snapshot.elapsedSeconds = 0.01
        try store.checkpoint(snapshot)
    }
    let audioURL = directory.appendingPathComponent("audio.caf")
    let originalAudio = try Data(contentsOf: audioURL)
    try originalAudio.dropLast().write(to: audioURL)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let originalManifest = try Data(contentsOf: manifestURL)
    do {
        _ = try RecoveryStore.recover(directory: directory, outputDirectory: root)
        Issue.record("Recovery accepted a truncated committed extent")
    } catch {
        #expect(String(describing: error).contains("truncated"))
    }
    #expect(try Data(contentsOf: manifestURL) == originalManifest)
    #expect(try Data(contentsOf: audioURL) == originalAudio.dropLast())
}
