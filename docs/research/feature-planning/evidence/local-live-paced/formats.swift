import Foundation
import Speech
@main struct Formats {
 static func main() async {
  for locale in ["en_US", "zh_CN"] {
   let t = SpeechTranscriber(locale: Locale(identifier: locale), preset: .progressiveTranscription)
   print("\(locale): \(String(describing: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])))")
  }
 }
}
