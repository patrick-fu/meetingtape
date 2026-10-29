import Foundation
import Testing
@testable import MeetingTapeTranscription

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGTAPE_TEXT_TRANSLATION_SMOKE_ROOT"] != nil), .timeLimit(.minutes(1)))
func syntheticTextTranslationUsesSelectedProviderAndSkipsTargetLanguage() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["MEETINGTAPE_TEXT_TRANSLATION_SMOKE_ROOT"]))
    let provider = try #require(SubtitleTranslationProvider(rawValue: environment["MEETINGTAPE_TEXT_TRANSLATION_SMOKE_PROVIDER"] ?? "local"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var responses: [CaptionTranslation] = []
    let credential = DoubaoCredential(apiKey: environment["DOUBAO_API_KEY"] ?? "", appID: environment["DOUBAO_APPID"] ?? "", accessToken: environment["DOUBAO_ACCESS_TOKEN"] ?? "")
    for (text, target) in [("Please keep the recording local.", "zh-Hans"), ("请把录音保留在本地。", "en")] {
        let result = try await TextTranslation.translate(text, target: target, provider: provider, credential: credential)
        #expect(result.state == .translated)
        #expect(result.text?.isEmpty == false)
        responses.append(result)
    }
    let skipped = try await TextTranslation.translate("This meeting starts at nine thirty.", target: "en", provider: provider, credential: credential)
    #expect(skipped.state == .sameLanguage && skipped.text == nil && skipped.provider == "language-detection")
    responses.append(skipped)
    try JSONEncoder().encode(responses).write(to: root.appendingPathComponent(provider.rawValue + "-translation-results.json"), options: .atomic)
}
