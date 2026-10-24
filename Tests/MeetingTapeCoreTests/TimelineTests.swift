import Testing
@testable import MeetingTapeCore

@Test func partialAudioBlocksPreserveSamplesAndValidSilence() throws {
    let timeline = CaptureTimeline()
    let samples = Array(repeating: [Float(0.2), Float(-0.1)], count: 480).flatMap { $0 }
    try timeline.insert(CapturedAudio(source: .system, hostTime: 1, sampleRate: 48_000,
                                     channels: 2, generation: 1, samples: samples), frame: 240)
    let first = timeline.render(at: 0, count: 480)
    #expect(first.hasAnyAudio)
    #expect(!first.hasSystem)
    #expect(first.systemLeft.prefix(240).allSatisfy { $0 == 0 })
    #expect(first.systemLeft.suffix(240).allSatisfy { abs($0 - 0.2) < 0.00001 })
    #expect(first.systemRight.suffix(240).allSatisfy { abs($0 + 0.1) < 0.00001 })
    try timeline.insert(CapturedAudio(source: .system, hostTime: 2, sampleRate: 48_000,
                                     channels: 2, generation: 1, samples: [Float](repeating: 0, count: 960)), frame: 720)
    let silent = timeline.render(at: 720, count: 480)
    #expect(silent.hasSystem)
    #expect(silent.hasAnyAudio)
    #expect(silent.systemLeft.allSatisfy { $0 == 0 })
    #expect(!silent.hasMicrophone)
}
