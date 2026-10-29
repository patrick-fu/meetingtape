import AppKit
import MeetingTapeTranscription
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptExportButton: View {
    let item: RecordingItem
    let primary: String
    @State private var showing = false

    var body: some View {
        Button("导出 Markdown") { showing = true }
            .font(.system(size: 11))
            .sheet(isPresented: $showing) { TranscriptExportView(item: item, initialPrimary: primary) }
    }
}

private struct TranscriptExportView: View {
    @Environment(\.dismiss) private var dismiss
    let item: RecordingItem
    let initialPrimary: String
    @State private var versions: [TranscriptExportVersion] = []
    @State private var primary = ""
    @State private var includeVersions = false
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出 Markdown").font(.system(size: 20, weight: .semibold))
            Picker("主稿", selection: $primary) {
                ForEach(versions) { Text($0.title + ($0.exportable ? "" : "（正文不可读取）")).tag($0.id) }
            }
            Toggle("包含其他版本", isOn: $includeVersions)
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…") { export() }.keyboardShortcut(.defaultAction).disabled(busy || !versions.contains { $0.id == primary && $0.exportable })
            }
        }.padding(26).frame(width: 540)
            .task {
                do {
                    let id = item.snapshot.sessionID, title = item.title
                    let snapshot = try await Task.detached { try TranscriptExportSnapshot.load(id, title: title) }.value
                    versions = snapshot.versions
                    primary = versions.contains { $0.id == initialPrimary } ? initialPrimary : versions.first?.id ?? ""
                } catch { message = error.localizedDescription }
            }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = item.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; message = nil
        let arguments = ["transcribe", "export", item.snapshot.sessionID, "--primary", primary, "--title", item.title] + (includeVersions ? ["--include-versions"] : [])
        Task {
            do {
                let data = try await RecordingClient().data(arguments)
                try data.write(to: destination, options: .atomic)
                dismiss()
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
