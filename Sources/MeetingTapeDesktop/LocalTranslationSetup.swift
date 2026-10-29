import MeetingTapeTranscription
import SwiftUI
@preconcurrency import Translation

@available(macOS 26.0, *)
struct LocalTranslationSetup: View {
    let target: String
    @State private var configuration: TranslationSession.Configuration?
    @State private var status = ""
    @State private var busy = false
    private var source: String { target == "en" ? "zh-Hans" : "en" }

    var body: some View {
        HStack {
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("准备语言包") {
                busy = true
                if configuration == nil { configuration = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target)) }
                else { configuration?.invalidate() }
            }.font(.system(size: 11)).disabled(busy)
        }
        .task { await refresh() }
        .translationTask(configuration) { session in
            do { try await session.prepareTranslation(); await refresh() }
            catch { status = "语言包未就绪，请重试。" }
            busy = false
        }
    }

    private func refresh() async {
        let availability = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch availability {
        case .installed: status = "本地语言包已就绪"
        case .supported: status = "首次使用需下载语言包"
        case .unsupported: status = "此语言对暂不支持本地翻译"
        @unknown default: status = "无法确认语言包状态"
        }
    }
}
