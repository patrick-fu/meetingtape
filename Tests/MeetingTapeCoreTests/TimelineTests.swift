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

@Test func continuousMicrophonePacketsKeepTheirOriginalSamples() throws {
    let timeline = CaptureTimeline()
    let packetFrames = 4_800
    for packet in 0..<8 {
        let samples = (0..<packetFrames).map { Float(packet * packetFrames + $0) / 100_000 }
        try timeline.insert(CapturedAudio(source: .microphone, hostTime: UInt64(packet + 1),
                                         sampleRate: 48_000, channels: 1, generation: 1,
                                         samples: samples), frame: Int64(packet * packetFrames))
    }
    try timeline.flush()
    try timeline.flush()
    var uncoveredBlocks = 0
    var mismatchedSamples = 0
    for frame in stride(from: 0, to: 8 * packetFrames, by: 480) {
        let audio = timeline.render(at: Int64(frame), count: 480)
        if !audio.hasMicrophone { uncoveredBlocks += 1 }
        let expected = (frame..<(frame + 480)).map { Float($0) / 100_000 }
        mismatchedSamples += zip(audio.microphone, expected).filter { $0 != $1 }.count
    }
    #expect(uncoveredBlocks == 0)
    #expect(mismatchedSamples == 0)
}

@Test func convertedTailsSurviveGapsAndGenerationChanges() throws {
    for rate in [44_100.0, 96_000.0] {
        for expireBeforeNextPacket in [false, true] {
            let timeline = CaptureTimeline()
            let frames = Int(rate / 10)
            for packet in 0..<8 {
                try timeline.insert(CapturedAudio(source: .microphone, hostTime: UInt64(packet + 1),
                                                 sampleRate: rate, channels: 1, generation: 1,
                                                 samples: [Float](repeating: 0.2, count: frames)),
                                    frame: Int64(packet * 4_800))
            }
            if expireBeforeNextPacket { try timeline.prepare(until: 62_400) }
            let first = timeline.render(at: 0, count: 38_400)
            if expireBeforeNextPacket {
                let complete = first.hasMicrophone
                #expect(complete)
            }
            try timeline.insert(CapturedAudio(source: .microphone, hostTime: 9,
                                             sampleRate: rate, channels: 1,
                                             generation: expireBeforeNextPacket ? 1 : 2,
                                             samples: [Float](repeating: -0.2, count: frames)), frame: 62_400)
            try timeline.prepare(until: 67_200)
            let oldTail = timeline.render(at: 37_920, count: 480)
            let oldTailComplete = oldTail.hasMicrophone
            #expect(oldTailComplete)
            let gap = timeline.render(at: 38_400, count: 24_000)
            let gapIsEmpty = !gap.hasAnyAudio && gap.microphone.allSatisfy { $0 == 0 }
            #expect(gapIsEmpty)
            let resumed = timeline.render(at: 62_400, count: 4_800)
            let resumedComplete = resumed.hasMicrophone
            #expect(resumedComplete)
            let resumedFinite = resumed.microphone.allSatisfy(\.isFinite)
            #expect(resumedFinite)
        }
    }
}
