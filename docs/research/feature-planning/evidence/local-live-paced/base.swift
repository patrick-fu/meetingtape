import Foundation
import Speech
import AVFoundation
@main struct Probe {
 static func main() async throws {
  let t = SpeechTranscriber(locale: Locale(identifier: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en_US"), preset: .progressiveTranscription)
  let f = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
  let a = SpeechAnalyzer(modules:[t])
  let results = Task { do { for try await r in t.results { print("final=\(r.isFinal) text=\(String(r.text.characters))") } } catch { print("result-error=\(error)") } }
  try await a.start(inputAudioFile:f, finishAfterFile:false)
  try await a.finalizeAndFinishThroughEndOfInput()
  await results.value
 }
}
