import Foundation
import NaturalLanguage
import Translation

public enum TextTranslation {
    public static func translate(_ text: String, target: String, provider: SubtitleTranslationProvider) async throws -> CaptionTranslation {
        try await translate(text, target: target, provider: provider, credential: nil)
    }

    public static func translate(_ text: String, target: String, provider: SubtitleTranslationProvider, credential: DoubaoCredential?) async throws -> CaptionTranslation {
        guard SubtitleLanguage.identifiers.contains(target), !text.isEmpty, text.utf8.count <= 16384 else {
            throw TranscriptionFailure("翻译目标语言或文本长度无效。")
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let source = recognizer.dominantLanguage?.rawValue
        if let source, sameLanguage(source, target) {
            return CaptionTranslation(targetLanguage: target, state: .sameLanguage, provider: "language-detection")
        }
        let began = ContinuousClock.now
        var result: CaptionTranslation
        switch provider {
        case .local:
            guard #available(macOS 26.0, *) else { throw TranscriptionFailure("本地实时翻译需要 macOS 26；旧系统可手动选择豆包文本翻译。") }
            guard let source else { throw TranscriptionFailure("暂时无法判断这段文字的语言。") }
            let availability = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
            guard availability == .installed else {
                throw TranscriptionFailure(availability == .unsupported ? "此语言对暂不支持本地翻译。" : "请先在设置中准备本地翻译语言包。")
            }
            let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
            guard await session.isReady else { throw TranscriptionFailure("本地翻译语言包尚未就绪。") }
            let response = try await session.translate(text)
            result = CaptionTranslation(targetLanguage: target, text: response.targetText, state: .translated, provider: "apple-local")
        case .doubao:
            result = try await cloud(text, target: target, credential: credential)
        }
        let elapsed = began.duration(to: ContinuousClock.now).components
        result.elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return result
    }

    static func sameLanguage(_ source: String, _ target: String) -> Bool {
        if source.hasPrefix("zh") || target.hasPrefix("zh") {
            let normalized = source == "zh" ? "zh-Hans" : source
            return normalized == target
        }
        return source.split(separator: "-").first == target.split(separator: "-").first
    }

    private static func cloud(_ text: String, target: String, credential: DoubaoCredential?) async throws -> CaptionTranslation {
        let credential = try credential ?? TranscriptionCredentials.load()
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("volc.speech.mt", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Request-Id")
        if !credential.apiKey.isEmpty { request.setValue(credential.apiKey, forHTTPHeaderField: "X-Api-Key") }
        else {
            request.setValue(credential.appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(credential.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["target_language": target == "zh-Hans" ? "zh" : target, "text_list": [text]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TranscriptionFailure("豆包翻译未返回有效响应。") }
        let payload = data.count <= 1_048_576 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let serviceCode = payload?["code"] as? Int
        guard response.statusCode == 200 else {
            if (payload?["message"] as? String)?.contains("requested resource not granted") == true {
                throw TranscriptionFailure("当前豆包凭据未获 volc.speech.mt 翻译权限，请在火山引擎开通后重试。")
            }
            let code = serviceCode.map { "，服务码 \($0)" } ?? ""
            throw TranscriptionFailure("豆包文本翻译失败（HTTP \(response.statusCode)\(code)），请检查服务状态和 volc.speech.mt 权限。")
        }
        guard let payload,
              let code = payload["code"] as? Int else { throw TranscriptionFailure("豆包文本翻译响应无效。") }
        guard code == 20_000_000 else { throw TranscriptionFailure("豆包文本翻译失败（\(code)），请检查翻译权限。") }
        guard let content = payload["data"] as? [String: Any], let list = content["translation_list"] as? [[String: Any]],
              list.count == 1, let translated = list[0]["translation"] as? String, !translated.isEmpty,
              translated.utf8.count <= 65536 else { throw TranscriptionFailure("豆包文本翻译未返回译文。") }
        let usage = (list[0]["usage"] as? [String: Int])?.filter { ["prompt_tokens", "completion_tokens", "total_tokens"].contains($0.key) && $0.value >= 0 }
        return CaptionTranslation(targetLanguage: target, text: translated, state: .translated, provider: "volc.speech.mt", usage: usage)
    }
}
