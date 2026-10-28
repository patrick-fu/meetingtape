import AppKit
import MeetingTapeTranscription
import SwiftUI

struct LiveCaptionArchiveView: View {
    @ObservedObject var model: AppModel
    let item: RecordingItem
    let archive: LiveCaptionArchive

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("实时字幕").font(.system(size: 13, weight: .semibold))
                if !archive.complete { Text("部分字幕").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                TranscriptExportButton(item: item, primary: "live")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(archive.segments.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .disabled(archive.segments.isEmpty).accessibilityLabel("复制实时字幕")
            }
            if let message = archive.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            if archive.segments.isEmpty { Text("未识别到语音").font(.system(size: 12)).foregroundStyle(.secondary) }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(archive.segments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Button(recordingTime(segment.start)) { model.playSegment(segment.start) }
                            .font(.system(size: 10, design: .monospaced)).buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(model.active || model.operation != nil || !item.exists)
                            .accessibilityLabel("从 \(recordingTime(segment.start)) 回听实时字幕")
                        Text(segment.text).font(.system(size: 14)).foregroundStyle(segment.final ? .primary : .secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
