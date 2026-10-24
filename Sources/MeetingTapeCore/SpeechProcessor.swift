import APMBridge

enum SpeechProcessorError: Error, Equatable, CustomStringConvertible {
    case invalidBlock(String)
    case processingFailed(String)

    var description: String {
        switch self {
        case .invalidBlock(let reason):
            return reason
        case .processingFailed(let reason):
            return reason
        }
    }
}

final class SpeechProcessor {
    private let processor: OpaquePointer

    init() throws {
        guard let created = meetingtape_apm_create() else {
            throw SpeechProcessorError.processingFailed("WebRTC APM create failed")
        }
        processor = created
    }

    deinit {
        meetingtape_apm_destroy(processor)
    }

    func process(
        microphone: [Float],
        referenceLeft: [Float],
        referenceRight: [Float],
        delayMilliseconds: Int
    ) throws -> [Float] {
        let frameCount = Int(MEETINGTAPE_APM_FRAME_COUNT)
        guard microphone.count == frameCount,
              referenceLeft.count == frameCount,
              referenceRight.count == frameCount
        else {
            throw SpeechProcessorError.invalidBlock("each input must contain \(frameCount) samples")
        }
        guard microphone.allSatisfy(\.isFinite),
              referenceLeft.allSatisfy(\.isFinite),
              referenceRight.allSatisfy(\.isFinite)
        else {
            throw SpeechProcessorError.invalidBlock("inputs must be finite")
        }
        guard let delay = Int32(exactly: delayMilliseconds) else {
            throw SpeechProcessorError.invalidBlock("delay does not fit a C int")
        }

        var output = [Float](repeating: 0, count: frameCount)
        let code: Int32 = microphone.withUnsafeBufferPointer { microphone in
            referenceLeft.withUnsafeBufferPointer { referenceLeft in
                referenceRight.withUnsafeBufferPointer { referenceRight in
                    output.withUnsafeMutableBufferPointer { output in
                        guard let microphonePointer = microphone.baseAddress,
                              let leftPointer = referenceLeft.baseAddress,
                              let rightPointer = referenceRight.baseAddress,
                              let outputPointer = output.baseAddress
                        else {
                            return 2
                        }
                        return meetingtape_apm_process(
                            processor,
                            microphonePointer,
                            leftPointer,
                            rightPointer,
                            Int32(frameCount),
                            delay,
                            outputPointer
                        )
                    }
                }
            }
        }
        guard code == 0 else {
            throw Self.error(for: code)
        }
        return output
    }

    private static func error(for code: Int32) -> SpeechProcessorError {
        switch code {
        case 1:
            return .processingFailed("null audio processor")
        case 2:
            return .invalidBlock("each input must contain \(MEETINGTAPE_APM_FRAME_COUNT) samples")
        case 3:
            return .invalidBlock("inputs must be finite")
        case 4:
            return .processingFailed("reverse stream failed")
        case 5:
            return .processingFailed("stream delay was rejected")
        case 6:
            return .processingFailed("capture stream failed")
        case 7:
            return .processingFailed("output was not finite")
        default:
            return .processingFailed("audio processing failed (\(code))")
        }
    }
}
