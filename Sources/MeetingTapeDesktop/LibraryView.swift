import SwiftUI
import MeetingTapeTranscription

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var settings = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 258)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let item = model.selected {
                    RecordingDetail(model: model, item: item).id(item.id)
                } else {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(model.records.isEmpty ? "还没有录音" : "选择一段录音").font(.system(size: 18, weight: .medium)).padding(.top, 12)
                    Spacer()
                }
                if let message = model.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.system(size: 11)).textSelection(.enabled).lineLimit(5)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                    }.padding(14).background(Color.orange.opacity(0.07))
                }
                if model.libraryReadOnly {
                    Text("资料库索引无法保存，整理功能暂不可用。录音文件仍保留在保存位置。")
                        .font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(13)
                }
                if let message = model.savedMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(message).font(.system(size: 11))
                        Spacer()
                        Button("查看录音") { model.onOpenLibrary?(); model.savedMessage = nil }.buttonStyle(.plain).foregroundStyle(.blue)
                        Button { model.savedMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭保存提示")
                    }.padding(12).background(Color.green.opacity(0.04))
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 540)
        .sheet(isPresented: $settings) { SettingsView(model: model) { settings = false } }
        .environmentObject(model.transcription)
    }

    private var toolbar: some View {
        HStack {
            Text("资料库").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if model.active { Circle().fill(.red.opacity(0.75)).frame(width: 5, height: 5); Text(recordingTime(model.snapshot?.elapsedSeconds ?? 0)).monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary) }
            Button {
                if model.active { model.panelExpanded = true; model.onShowRecordingPanel?(); model.onChange?() } else { model.start() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.active ? "pip" : "record.circle")
                    Text(model.active ? "显示录音窗口" : model.operation ?? "开始录音")
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                    .background(model.active ? Color.primary.opacity(0.05) : Color.accentColor).foregroundStyle(model.active ? Color.primary : .white).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(model.operation != nil || model.snapshot?.state == .failed)
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 30) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("录音设置")
        }.padding(.horizontal, 24).frame(height: 58)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MeetingTape").font(.system(size: 15, weight: .semibold)).padding(.top, 24).padding(.horizontal, 23)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("搜索录音", text: $model.query).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("搜索录音")
            }.padding(9).background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.04))).padding(17)
            VStack(spacing: 3) {
                filterButton("all", "所有录音", "tray.full")
                filterButton("starred", "已标记", "star")
                filterButton("today", "今天", "calendar")
            }.padding(.horizontal, 12).padding(.bottom, 15)
            Divider()
            if model.active {
                Button { model.panelExpanded = true; model.onShowRecordingPanel?(); model.onChange?() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(.red.opacity(0.75))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.activeTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(model.statusText).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(13).background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 10).accessibilityLabel("显示正在录制的录音")
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.visibleRecords) { item in
                        Button { model.select(item.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform").font(.system(size: 14)).foregroundStyle(.blue.opacity(0.65)).frame(width: 29, height: 31).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(item.date, format: .dateTime.month().day())
                                        Text("·")
                                        Text(recordingTime(item.snapshot.elapsedSeconds))
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if item.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange.opacity(0.65)) }
                            }.padding(.horizontal, 10).padding(.vertical, 12).contentShape(Rectangle())
                                .background(model.selectedID == item.id ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel(item.title)
                    }
                    if model.visibleRecords.isEmpty, !model.records.isEmpty { Text("没有找到录音").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 35) }
                }.padding(9)
            }
            Divider()
            Button { model.chooseDirectory() } label: {
                HStack(spacing: 8) { Image(systemName: "folder"); Text(URL(fileURLWithPath: model.outputDirectory).lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) }.font(.system(size: 11)).foregroundStyle(.secondary).padding(17)
            }.buttonStyle(.plain).disabled(model.active || model.operation != nil).accessibilityLabel("选择录音保存位置")
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
    }

    private func filterButton(_ key: String, _ title: String, _ symbol: String) -> some View {
        Button { model.filter = key } label: {
            HStack(spacing: 11) { Image(systemName: symbol).frame(width: 17); Text(title); Spacer() }.font(.system(size: 12, weight: model.filter == key ? .medium : .regular)).padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(model.filter == key ? Color.accentColor : .secondary)
                .background(model.filter == key ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

private struct RecordingDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var captions: LiveCaptionModel
    let item: RecordingItem
    @State private var editedTitle = ""
    @State private var liveArchive: LiveCaptionArchive?
    @State private var liveArchiveError: String?
    @FocusState private var editing: Bool

    init(model: AppModel, item: RecordingItem) {
        self.model = model; self.item = item; captions = model.liveCaptions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("录音标题", text: $editedTitle).font(.system(size: 24, weight: .semibold)).textFieldStyle(.plain).focused($editing).onSubmit { commitTitle() }.disabled(model.libraryReadOnly).accessibilityLabel("录音标题")
                        Text(item.date.formatted(date: .abbreviated, time: .shortened) + "  ·  " + recordingTime(item.snapshot.elapsedSeconds)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.toggleStar(item.id) } label: { Image(systemName: item.starred ? "star.fill" : "star").foregroundStyle(item.starred ? .orange.opacity(0.75) : .secondary).frame(width: 30, height: 30) }.buttonStyle(.plain).disabled(model.libraryReadOnly).accessibilityLabel(item.starred ? "取消标记" : "标记录音")
                }
                waveformPanel
                if let liveArchive { LiveCaptionArchiveView(model: model, item: item, archive: liveArchive) }
                if let liveArchiveError { Text(liveArchiveError).font(.system(size: 11)).foregroundStyle(.orange) }
                TranscriptSection(model: model, item: item)
                HStack(alignment: .top, spacing: 35) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("录音来源").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        sourceRow("系统音频", "左声道", "speaker.wave.2", .blue)
                        sourceRow("麦克风", "右声道", "mic", .teal)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 15) {
                        Text("保存位置").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Button { model.reveal(item) } label: { Label(item.url.deletingLastPathComponent().lastPathComponent, systemImage: "folder").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        if item.snapshot.rawOutputPath != nil { Text("已保留原始麦克风").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
                if !item.snapshot.degradedIntervals.isEmpty || !item.snapshot.interruptions.isEmpty || item.snapshot.recoveryNote != nil {
                    DisclosureGroup("录音状态记录") {
                        VStack(alignment: .leading, spacing: 8) {
                            if item.snapshot.recoveryNote != nil { Text("此录音从最后一次安全保存的位置恢复，此后的音频可能缺失。") }
                            ForEach(Array(item.snapshot.interruptions.enumerated()), id: \.offset) { _, interval in Text("\(recordingTime(interval.startSeconds))–\(recordingTime(interval.endSeconds))  \(interval.source == .system ? "系统音频" : interval.source == .microphone ? "麦克风音频" : "音源")中断") }
                            ForEach(Array(item.snapshot.degradedIntervals.enumerated()), id: \.offset) { _, interval in Text("\(recordingTime(interval.startSeconds))–\(recordingTime(interval.endSeconds))  麦克风使用原始音频") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(item.exists ? "双声道 AAC · 48 kHz" : "文件已移动或丢失").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("在 Finder 中显示") { model.reveal(item) }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.blue)
                }
            }.padding(31)
        }.onAppear { editedTitle = item.title }.onChange(of: editing) { _, focused in if !focused { commitTitle() } }
            .task(id: "\(item.snapshot.sessionID)-\(captions.archiveRevision)") {
                do { liveArchive = try await captions.store.load(item.snapshot.sessionID); liveArchiveError = nil }
                catch { liveArchiveError = "实时字幕无法读取：\(error.localizedDescription)" }
            }
    }

    private func commitTitle() { if editedTitle != item.title { model.rename(item.id, to: editedTitle) } }

    private var waveformPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("系统音频", systemImage: "circle.fill").foregroundStyle(.blue.opacity(0.6))
                Label("麦克风", systemImage: "circle.fill").foregroundStyle(.teal.opacity(0.65))
                Spacer()
            }.font(.system(size: 9)).padding(16)
            Divider().opacity(0.45)
            VStack(spacing: 16) {
                RecordedWave(levels: model.waveform.system, color: .blue.opacity(0.45)).frame(height: 48)
                RecordedWave(levels: model.waveform.microphone, color: .teal.opacity(0.5)).frame(height: 48)
                HStack { Text("00:00"); Spacer(); Text(recordingTime(item.snapshot.elapsedSeconds / 2)); Spacer(); Text(recordingTime(item.snapshot.elapsedSeconds)) }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(18)
            Divider().opacity(0.45)
            HStack(spacing: 12) {
                Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 13)).foregroundStyle(.white).frame(width: 33, height: 33).background(Color.accentColor, in: Circle()) }.buttonStyle(.plain).disabled(!model.playing && (!item.exists || model.active || model.operation != nil)).accessibilityLabel(model.playing ? "暂停播放" : "播放录音")
                Text(recordingTime(model.playbackSeconds)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 42)
                Slider(value: Binding(get: { model.playbackSeconds }, set: { model.seek($0) }), in: 0...max(model.playbackDuration, 1)).controlSize(.mini).disabled(model.playbackDuration == 0).accessibilityLabel("播放进度")
                Text(recordingTime(model.playbackDuration > 0 ? model.playbackDuration : item.snapshot.elapsedSeconds)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(15)
        }.background(Color.blue.opacity(0.022), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.045)))
    }

    private func sourceRow(_ title: String, _ description: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color.opacity(0.7)).frame(width: 30, height: 32).background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12)); Text(description).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}

struct RecordedWave: View {
    let levels: [Double]
    let color: Color
    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let step = size.width / Double(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(2, meterHeight(level) * size.height)
                let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: max(1, step - 1.5), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
            }
        }.accessibilityLabel("录音波形")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var dismiss: () -> Void
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置").font(.system(size: 20, weight: .semibold))
            Picker("设置分类", selection: $tab) { Text("录音").tag(0); Text("转写与模型").tag(1) }.pickerStyle(.segmented)
            if tab == 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("保存位置").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Text(model.outputDirectory).font(.system(size: 12)).lineLimit(2).textSelection(.enabled); Spacer(); Button("更改") { model.chooseDirectory() } }.disabled(model.active || model.operation != nil)
            }
            Toggle("保留原始麦克风音轨", isOn: Binding(get: { model.keepRaw }, set: { model.setKeepRaw($0) })).toggleStyle(.switch).controlSize(.small).disabled(model.active || model.operation != nil)
            if model.retainedRecoveryPath != nil { Button("查看上次恢复材料") { model.revealRecovery() }.font(.system(size: 11)) }
            } else { TranscriptionSettingsView(captions: model.liveCaptions).environmentObject(model.transcription) }
            HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(27).frame(width: tab == 0 ? 500 : 600)
    }
}
