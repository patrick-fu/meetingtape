import MeetingTapeTranscription
import SwiftUI

struct MeetingMinutesView: View {
    @ObservedObject var model: AppModel
    let item: RecordingItem
    @ObservedObject private var minutes: MeetingMinutesModel
    @ObservedObject private var transcription: TranscriptionModel
    @ObservedObject private var captions: LiveCaptionModel
    @State private var versions: [MeetingMinutesVersion] = []
    @State private var selectedID = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var sourceChanged = false
    @State private var message: String?
    @State private var run: MinutesRun?
    @State private var citation: TranscriptCitation?

    init(model: AppModel, item: RecordingItem) {
        self.model = model; self.item = item
        minutes = model.minutes; transcription = model.transcription; captions = model.liveCaptions
    }

    private var sessionID: String { item.snapshot.sessionID }
    private var version: MeetingMinutesVersion? { versions.first { $0.id == selectedID } }
    private var busy: Bool { minutes.busySessionIDs.contains(sessionID) }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 20) {
                toolbar
                if let message = message ?? minutes.errors[sessionID] {
                    Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成纪要…").foregroundStyle(.secondary)
                        Spacer()
                        Button("取消生成") { _ = minutes.cancel(sessionID) }
                    }
                } else if let run, run.state == "interrupted" || run.state == "failed" {
                    Text(run.state == "interrupted" ? "上次生成已中断，可重新生成。" : "上次生成未完成，可重新生成。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let version {
                    if sourceChanged {
                        HStack {
                            Label("转写已更新", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                            Spacer()
                            Button("更新纪要") { generate() }.disabled(busy || editing)
                        }.font(.system(size: 12))
                    }
                    if editing {
                        TextEditor(text: $draft)
                            .font(.system(size: 14, design: .monospaced)).frame(minHeight: 380)
                            .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        HStack {
                            Spacer()
                            Button("取消") { editing = false }.disabled(saving)
                            Button("保存为新版本") { save(version) }
                                .buttonStyle(.borderedProminent).disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        MinutesMarkdownView(bodyText: version.body) { index in
                            guard version.citations.indices.contains(index) else { return }
                            let value = version.citations[index]
                            citation = value; model.locateSegment(value.start)
                        }
                        if !version.citations.isEmpty {
                            DisclosureGroup("引用依据（\(version.citations.count)）") {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(Array(version.citations.enumerated()), id: \.element.id) { index, value in
                                        DisclosureGroup("[\(index + 1)] \(value.model) · \(minutesTime(value.start))") {
                                            MinutesCitationView(citation: value, onLocate: { model.locateSegment(value.start) }, onPlay: { model.playSegment(value.start) })
                                        }
                                    }
                                }.padding(.top, 8)
                            }.font(.system(size: 12))
                        }
                    }
                    Divider()
                    ConfirmedTermsView(sessionID: sessionID, candidates: version.candidateTerms, onLocate: { model.locateSegment($0.start) }, onChange: { minutes.refresh() })
                } else if !busy {
                    ContentUnavailableView {
                        Label("会议纪要", systemImage: "note.text")
                    } description: {
                        Text("根据这场录音的转写生成概览、讨论、决策与待办。")
                    } actions: {
                        Button("生成纪要") { generate() }.buttonStyle(.borderedProminent)
                        Button("纪要设置") { model.onOpenMinutesSettings?() }
                    }.frame(maxWidth: .infinity, minHeight: 260)
                    ConfirmedTermsView(sessionID: sessionID, onLocate: { model.locateSegment($0.start) }, onChange: { minutes.refresh() })
                }
            }.padding(24).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task(id: sessionID) { selectedID = ""; editing = false; citation = nil; reload() }
        .onReceive(minutes.$revision) { _ in reload() }
        .onReceive(transcription.$results) { _ in refreshSources() }
        .onReceive(captions.$archiveRevision) { _ in refreshSources() }
        .onChange(of: selectedID) { _, _ in citation = nil; refreshSources() }
        .popover(item: $citation) { value in
            MinutesCitationView(citation: value, onLocate: { model.locateSegment(value.start) }, onPlay: { model.playSegment(value.start) })
                .padding(18).frame(width: 430)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("会议纪要").font(.system(size: 20, weight: .semibold))
            Spacer()
            if !versions.isEmpty {
                Picker("版本", selection: $selectedID) {
                    ForEach(Array(versions.enumerated().reversed()), id: \.element.id) { index, value in
                        Text("版本 \(index + 1) · \(value.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(value.id)
                    }
                }.labelsHidden().frame(maxWidth: 260).disabled(editing || saving)
                if let version {
                    Button("编辑") { draft = version.body; editing = true }.disabled(editing || saving)
                    TranscriptExportButton(item: item, primary: "minutes:" + version.id)
                }
                Button("重新生成") { generate() }.disabled(busy || editing || saving)
            }
            Button { model.onOpenMinutesSettings?() } label: { Image(systemName: "gearshape") }
                .help("纪要设置").accessibilityLabel("纪要设置")
        }.controlSize(.small)
    }

    private func reload() {
        do {
            versions = try minutes.store.readSnapshot(sessionID: sessionID)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.last?.id ?? "" }
            run = try minutes.lastRun(sessionID)
            refreshSources()
        } catch { message = error.localizedDescription }
    }

    private func refreshSources() {
        guard let version else { sourceChanged = false; return }
        do { sourceChanged = try version.sourcesChanged(MeetingMinutesSources.load(sessionID).citations) }
        catch { message = error.localizedDescription }
    }

    private func generate() {
        message = nil
        Task {
            do {
                let result = try await minutes.generate(sessionID: sessionID, parentID: version?.id)
                reload(); selectedID = result.id
            } catch is CancellationError { reload() }
            catch { message = error.localizedDescription; reload() }
        }
    }

    private func save(_ version: MeetingMinutesVersion) {
        saving = true; message = nil
        Task {
            defer { saving = false }
            do {
                let result = try await minutes.edit(sessionID: sessionID, body: draft, parentID: version.id)
                editing = false; reload(); selectedID = result.id
            } catch { message = error.localizedDescription }
        }
    }
}

private struct MinutesMarkdownView: View {
    let bodyText: String
    let onCitation: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(bodyText.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { row(line) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "meetingtape-citation", let index = Int(url.host ?? "") else { return .discarded }
            onCitation(index - 1); return .handled
        })
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).font(.system(size: 23, weight: .semibold)).padding(.top, 8)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).font(.system(size: 17, weight: .semibold)).padding(.top, 12)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).font(.system(size: 15, weight: .semibold)).padding(.top, 8)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(trimmed.dropFirst(2)))
            }.font(.system(size: 14))
        } else if trimmed.hasPrefix("> ") {
            inline(String(trimmed.dropFirst(2))).font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.leading, 12)
        } else { inline(line).font(.system(size: 14)) }
    }

    private func inline(_ value: String) -> Text {
        let local = value.replacingOccurrences(of: "(#minutes-ref-", with: "(meetingtape-citation://")
        return Text((try? AttributedString(markdown: local, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

struct MinutesCitationView: View {
    let citation: TranscriptCitation
    var onLocate: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(citation.model) · \(citation.source.name)").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(minutesTime(citation.start))–\(minutesTime(citation.end))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(citation.text).font(.system(size: 14)).textSelection(.enabled)
            HStack {
                if let onLocate { Button("定位原文", action: onLocate) }
                if let onPlay { Button("播放", action: onPlay) }
            }.controlSize(.small)
        }.padding(.vertical, 6)
    }
}

private func minutesTime(_ value: Double) -> String {
    let seconds = Int(max(0, value))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}
