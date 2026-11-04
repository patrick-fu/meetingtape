import Foundation
import Speech
import AVFoundation
let origin = Date()
func log(_ s: String) { print(String(format:"%.3f", Date().timeIntervalSince(origin)), s); fflush(stdout) }
func run(_ label: String, _ path: String, _ locale: String) async throws {
 let f = try AVAudioFile(forReading: URL(fileURLWithPath:path), commonFormat: .pcmFormatInt16, interleaved: false)
 let t = SpeechTranscriber(locale: Locale(identifier:locale), preset:.progressiveTranscription)
 let a = SpeechAnalyzer(modules:[t])
 let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
 let result = Task { do { for try await r in t.results { log("\(label) final=\(r.isFinal) text=\(String(r.text.characters))") } } catch { log("\(label) result-error=\(error)") } }
 try await a.prepareToAnalyze(in:f.processingFormat)

 try await a.start(inputSequence:stream)
 let rate = f.processingFormat.sampleRate
 log("\(label) started rate=\(rate) frames=\(f.length) duration=\(Double(f.length)/rate)")
 let chunk = AVAudioFrameCount(rate * 0.2)
 while f.framePosition < f.length {
  let b = AVAudioPCMBuffer(pcmFormat:f.processingFormat, frameCapacity:chunk)!
  try f.read(into:b, frameCount:chunk)
  if b.frameLength == 0 { break }
  continuation.yield(AnalyzerInput(buffer:b))
  try await Task.sleep(nanoseconds: UInt64(Double(b.frameLength)/rate * 1_000_000_000))
 }
 log("\(label) EOF")
 continuation.finish()
 try await a.finalizeAndFinishThroughEndOfInput()
 log("\(label) finalized")
 await result.value
}
@main struct Main {
 static func main() async {
  do { async let en: Void = run("en", "en16.caf", "en_US"); async let zh: Void = run("zh", "zh16.caf", "zh_CN"); _ = try await (en, zh); log("complete") }
  catch { log("error=\(error)"); exit(1) }
 }
}
