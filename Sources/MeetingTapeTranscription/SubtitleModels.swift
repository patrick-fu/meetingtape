import Foundation

public enum SubtitleTranslationProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case local, doubao
    public var id: String { rawValue }
    public var name: String { self == .local ? "Apple 本地翻译" : "豆包文本翻译" }
}

public struct SubtitleOptions: Codable, Sendable, Equatable {
    public var transcription = true
    public var translation = false
    public var targetLanguage = "zh-Hans"
    public var provider: SubtitleTranslationProvider = .local
    public init() {}
}

public enum CaptionTranslationState: String, Codable, Sendable {
    case pending, translated, sameLanguage, failed
}

public struct CaptionTranslation: Codable, Sendable, Equatable {
    public var targetLanguage: String
    public var text: String?
    public var state: CaptionTranslationState
    public var provider: String
    public var elapsedSeconds: Double?
    public var usage: [String: Int]?
    public init(targetLanguage: String, text: String? = nil, state: CaptionTranslationState, provider: String, elapsedSeconds: Double? = nil, usage: [String: Int]? = nil) {
        self.targetLanguage = targetLanguage; self.text = text; self.state = state; self.provider = provider
        self.elapsedSeconds = elapsedSeconds; self.usage = usage
    }
}

public struct CaptionCoverage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var source: TranscriptSource
    public var feature: String
    public var state: String
    public var targetLanguage: String?
}

public struct CaptionConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: TranscriptSource
    public var start: Double
    public var end: Double
    public var complete: Bool
    public var elapsedSeconds: Double?
    public var state: String
}

public typealias CaptionTranslate = @Sendable (String, String, SubtitleTranslationProvider) async throws -> CaptionTranslation

public enum SubtitleLanguage {
    public static let identifiers = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es"]
    public static func name(_ identifier: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forIdentifier: identifier) ?? identifier
    }
}
