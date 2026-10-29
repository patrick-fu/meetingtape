import MeetingTapeTranscription
import SwiftUI

struct CaptionTextView: View {
    let segment: LiveCaptionSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !segment.text.isEmpty {
                Text(segment.text).font(.system(size: 14)).foregroundStyle(segment.final ? .primary : .secondary).textSelection(.enabled)
            }
            if let translation = segment.translation {
                switch translation.state {
                case .translated:
                    Text(SubtitleLanguage.name(translation.targetLanguage)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(translation.text ?? "").font(.system(size: 13)).foregroundStyle(.blue).textSelection(.enabled)
                case .sameLanguage:
                    if segment.text.isEmpty { Text(translation.text ?? "").font(.system(size: 14)).textSelection(.enabled) }
                    Text("无需翻译").font(.system(size: 9)).foregroundStyle(.tertiary)
                case .pending:
                    Text("正在翻译…").font(.system(size: 11)).foregroundStyle(.tertiary)
                case .failed:
                    Text("翻译暂不可用").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
    }
}
