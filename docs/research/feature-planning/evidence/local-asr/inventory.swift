import Foundation
import Speech
@main struct Probe {
 static func main() async {
  print("available=\(SpeechTranscriber.isAvailable)")
  print("installed=\(await SpeechTranscriber.installedLocales.map(\.identifier).sorted())")
  print("supported=\(await SpeechTranscriber.supportedLocales.map(\.identifier).sorted())")
 }
}
