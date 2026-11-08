import AppKit
import MeetingTapeTranscription
import SwiftUI

struct LiveCaptionArchiveView: View {
    @ObservedObject var model: AppModel
    let item: RecordingItem
    let archive: LiveCaptionArchive
    @State private var versionID = "live"
    @State private var busy = false
    @State private var error: String?
    private var selectedID: String? { versionID == "live" ? nil : versionID }
    private var selected: LiveCaptionArchive { archive.viewingTranslationVersion(selectedID) }
    private var canComplete: Bool {
        selected.segments.contains { segment in
            guard let state = segment.translation?.state, [.pending, .failed, .interrupted].contains(state) else { return false }
            return archive.translationJobs.contains { $0.segmentID == segment.id && $0.revision == segment.revision && !$0.input.isEmpty }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("实时字幕").font(.system(size: 13, weight: .semibold))
                if !selected.complete { Text("部分字幕").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                if !archive.translationVersions.isEmpty {
                    Picker("字幕版本", selection: $versionID) {
                        Text("实时原版").tag("live")
                        ForEach(archive.translationVersions) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 180)
                }
                if canComplete {
                    Button("补齐译文") {
                        busy = true; error = nil
                        Task {
                            do { versionID = try await model.liveCaptions.completeTranslations(item.snapshot.sessionID, parentID: selectedID) }
                            catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(busy || model.active)
                }
                TranscriptExportButton(item: item, primary: selectedID.map { "live:" + $0 } ?? "live")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selected.segments.map(\.plainText).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .disabled(selected.segments.isEmpty).accessibilityLabel("复制实时字幕")
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if let message = selected.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            if selected.segments.isEmpty { Text("暂无字幕正文").font(.system(size: 12)).foregroundStyle(.secondary) }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(selected.segments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Button(recordingTime(segment.start)) { model.playSegment(segment.start) }
                            .font(.system(size: 10, design: .monospaced)).buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(model.active || model.operation != nil || !item.exists)
                            .accessibilityLabel("从 \(recordingTime(segment.start)) 回听实时字幕")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.source.name).font(.system(size: 9)).foregroundStyle(.tertiary)
                            CaptionTextView(segment: segment)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
