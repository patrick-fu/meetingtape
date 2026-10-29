import SwiftUI
import MeetingTapeTranscription

struct TranscriptSection: View {
    @EnvironmentObject private var transcription: TranscriptionModel
    @ObservedObject var model: AppModel
    let item: RecordingItem
    @State private var selected: [TranscriptModel] = []
    @State private var reading: TranscriptModel?
    @State private var expanded: Set<Int> = []
    private var task: TranscriptionTask? { transcription.task(for: item.url.path) }
    private var results: [TranscriptModel: TranscriptResult] { task.flatMap { transcription.results[$0.id] } ?? [:] }
    private var result: TranscriptResult? { results[reading ?? task?.primaryModel ?? .qwen] }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("语音转写").font(.system(size: 17, weight: .semibold))
                Spacer()
                if let task { TranscriptExportButton(item: item, primary: task.id + ":" + (reading ?? task.primaryModel).rawValue) }
                if let task, !task.finished { ProgressView().controlSize(.small); Text(task.state == "waitingForRecording" ? "录音优先，转写等待中" : "正在转写").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 15) {
                ForEach(TranscriptModel.allCases) { family in
                    Toggle(family.name, isOn: Binding(get: { selected.contains(family) }, set: { value in
                        if value { selected.append(family) } else { selected.removeAll { $0 == family } }
                    })).toggleStyle(.checkbox).font(.system(size: 11))
                }
                Spacer(minLength: 0)
                Button(task == nil ? "转写" : "重新转写") { transcription.start(item, models: selected) }
                    .disabled(selected.isEmpty || transcription.busy || model.active || !item.exists || task?.finished == false)
            }
            if selected.contains(.doubao) { Text("本次会上传录音至豆包，使用你的账户计费。") .font(.system(size: 11)).foregroundStyle(.secondary) }
            if let message = transcription.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            if let task {
                HStack(spacing: 10) {
                    ForEach(task.runs) { run in
                        Button {
                            reading = run.model; expanded = []
                        } label: {
                            HStack(spacing: 5) {
                                Text(run.model.name)
                                if run.model == task.primaryModel { Text("主稿").font(.system(size: 9)) }
                                if run.state == .failed || run.state == .partial { Image(systemName: "exclamationmark.circle") }
                            }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background((reading ?? task.primaryModel) == run.model ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                ForEach(task.runs) { run in
                    ForEach(run.sources.filter { $0.state == .failed || $0.state == .partial }) { source in
                        HStack(alignment: .top) {
                            Text("\(run.model.name) · \(source.source.name)：\(source.error ?? "转写未完成")").font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                            Spacer()
                            Button("重试\(source.source.name)") { transcription.retry(task, model: run.model, source: source.source) }.font(.system(size: 11)).disabled(!task.finished || transcription.busy)
                        }
                    }
                }
                if let result {
                    if !result.missingSources.isEmpty {
                        Text(result.missingSources.map(\.name).joined(separator: "、") + "正文缺失，以下为可读取的部分结果").foregroundStyle(.orange).font(.system(size: 11))
                    } else if result.partial { Text("部分结果，转写尚未完整完成").foregroundStyle(.orange).font(.system(size: 11)) }
                    if result.segments.isEmpty { Text(result.partial ? "暂无已识别文本" : "未识别到语音").foregroundStyle(.secondary).font(.system(size: 12)) }
                    ForEach(result.segments) { segment in
                        VStack(alignment: .leading, spacing: 11) {
                            Button {
                                if expanded.contains(segment.id) { expanded.remove(segment.id) } else { expanded.insert(segment.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 13) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recordingTime(segment.start)).monospacedDigit()
                                        if task.recognitionMode == .separate { Text(segment.source.name).font(.system(size: 9)) }
                                        if segment.precision == "chunk" { Text("音频块").font(.system(size: 8)) }
                                    }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                                    Text(segment.text).font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                                    if differs(segment, from: result.model) { Circle().fill(Color.orange.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 6).accessibilityLabel("模型内容有差异") }
                                    Image(systemName: expanded.contains(segment.id) ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if expanded.contains(segment.id) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(task.runs) { run in
                                        if let other = results[run.model] {
                                            let matches = TranscriptComparison.matching(segment, in: other)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(run.model.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                                Text(matches.isEmpty ? "该时间范围无对应文本" : matches.map(\.text).joined(separator: " ")).font(.system(size: 12)).textSelection(.enabled)
                                            }
                                        }
                                    }
                                    Button { model.playSegment(segment.start) } label: { Label("从 \(recordingTime(segment.start)) 回听", systemImage: "play.fill") }
                                        .font(.system(size: 11)).disabled(model.active || model.operation != nil)
                                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                            }
                        }.padding(.vertical, 9)
                        Divider().opacity(0.45)
                    }
                } else if task.finished { Text("选择已完成的模型结果查看正文。") .font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .onAppear { selected = transcription.inventory?.settings.models ?? [.qwen] }
        .onChange(of: transcription.inventory?.settings.models) { _, models in if task == nil, let models { selected = models } }
    }

    private func differs(_ segment: TranscriptSegment, from source: TranscriptModel) -> Bool {
        results.contains { model, result in model != source && TranscriptComparison.differs(segment.text, from: TranscriptComparison.matching(segment, in: result).map(\.text).joined()) }
    }
}

struct TranscriptionSettingsView: View {
    @EnvironmentObject private var model: TranscriptionModel
    @ObservedObject var captions: LiveCaptionModel
    @State private var draft = TranscriptionSettings()
    @State private var apiKey = ""
    @State private var appID = ""
    @State private var accessToken = ""
    @State private var legacy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("实时字幕").font(.system(size: 13, weight: .semibold))
                    Toggle("实时转写", isOn: Binding(get: { captions.enabled }, set: { captions.setEnabled($0) })).font(.system(size: 12))
                    Toggle("字幕翻译", isOn: Binding(get: { captions.translationEnabled }, set: { captions.setTranslationEnabled($0) })).font(.system(size: 12))
                    Picker("目标语言", selection: Binding(get: { captions.targetLanguage }, set: { captions.setTargetLanguage($0) })) {
                        ForEach(SubtitleLanguage.identifiers, id: \.self) { Text(SubtitleLanguage.name($0)).tag($0) }
                    }.font(.system(size: 12))
                    Picker("翻译模型", selection: Binding(get: { captions.provider }, set: { captions.setProvider($0) })) {
                        ForEach(SubtitleTranslationProvider.allCases) { Text($0.name).tag($0) }
                    }.font(.system(size: 12))
                    if captions.provider == .local {
                        if #available(macOS 26, *) { LocalTranslationSetup(target: captions.targetLanguage).id(captions.targetLanguage) }
                        else { Text("本地实时翻译需要 macOS 26。").font(.system(size: 11)).foregroundStyle(.secondary) }
                    } else { Text("文字会发送至豆包，需开通 volc.speech.mt。使用下方自备凭据。").font(.system(size: 11)).foregroundStyle(.orange) }
                    if captions.anyEnabled { Text("实时语音识别会上传声音至豆包，使用你的账户计费。").font(.system(size: 11)).foregroundStyle(.orange) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("默认模型").font(.system(size: 13, weight: .semibold))
                    Picker("音源转写", selection: $draft.recognitionMode) {
                        Text("分开转写").tag(RecognitionMode.separate)
                        Text("合并转写").tag(RecognitionMode.merged)
                    }.font(.system(size: 12))
                    HStack(spacing: 20) {
                        ForEach(TranscriptModel.allCases) { family in
                            Toggle(family.name, isOn: Binding(get: { draft.models.contains(family) }, set: { value in
                                if value { draft.models.append(family) } else { draft.models.removeAll { $0 == family } }
                            })).toggleStyle(.checkbox).font(.system(size: 12))
                        }
                    }
                    if draft.models.count > 1 {
                        Picker("主稿优先", selection: Binding(get: { draft.models.first ?? .qwen }, set: { family in draft.models.removeAll { $0 == family }; draft.models.insert(family, at: 0) })) {
                            ForEach(draft.models) { Text($0.name).tag($0) }
                        }.font(.system(size: 11))
                    }
                    Toggle("录完自动转写", isOn: $draft.automatic).font(.system(size: 12))
                    if draft.automatic && draft.models.contains(.doubao) { Text("开启后，新录音保存完成即上传至豆包并使用你的账户计费。") .font(.system(size: 11)).foregroundStyle(.orange) }
                    Button("保存转写偏好") { model.save(draft) }.disabled(draft.models.isEmpty || model.busy)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("本地模型").font(.system(size: 13, weight: .semibold)); Spacer(); if let inventory = model.inventory { Text("\(inventory.memoryGiB) GB 内存").font(.system(size: 10)).foregroundStyle(.secondary) }; Button("查找已有模型") { model.discoverExisting() }.font(.system(size: 10)) }
                    Picker("模型版本", selection: $draft.profile) {
                        Text("节省内存 · 4-bit").tag("low-memory")
                        Text("标准 · 8-bit").tag("standard")
                    }.font(.system(size: 12))
                    if let inventory = model.inventory {
                        Text(inventory.localSupported ? "推荐\(inventory.recommendedProfile == "standard" ? "标准版" : "节省内存版")。首次完整安装约下载 \(draft.profile == "standard" ? "6" : "4.5") GB，按需下载所选模型。" : "当前本地模型需要至少 16 GB 内存，可使用豆包。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(TranscriptModel.allCases.filter(\.local)) { family in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(family.name).font(.system(size: 12))
                                    if let status = inventory.installations.first(where: { $0.model == family }) { Text(status.message).font(.system(size: 10)).foregroundStyle(status.state == "failed" ? .orange : .secondary).lineLimit(4) }
                                    else { Text(inventory.settings.installations[family.rawValue]?.available == true ? "已就绪" : "未安装").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if model.existingModels[family.rawValue] != nil && inventory.settings.installations[family.rawValue]?.available != true {
                                    Button("使用已有模型") { model.install(family, profile: draft.profile, reuse: true) }.font(.system(size: 11))
                                }
                                Button(inventory.settings.installations[family.rawValue]?.available == true ? "安装所选版本" : "一键安装") { model.install(family, profile: draft.profile, reuse: false) }.font(.system(size: 11))
                            }.disabled(!inventory.localSupported || model.busy || inventory.installations.contains { ["installing", "validating"].contains($0.state) })
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("豆包 · 自备 Key").font(.system(size: 13, weight: .semibold)); Spacer(); Text(model.inventory?.credentialConfigured == true ? "已配置" : "未配置").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Link("前往火山引擎获取 API Key", destination: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!).font(.system(size: 11))
                    Toggle("使用旧版 App ID 与 Access Token", isOn: $legacy).font(.system(size: 11))
                    if legacy { TextField("App ID", text: $appID); SecureField("Access Token", text: $accessToken) }
                    else { SecureField("API Key", text: $apiKey) }
                    HStack {
                        Button("存入钥匙串") {
                            model.credentials(DoubaoCredential(apiKey: legacy ? "" : apiKey, appID: legacy ? appID : "", accessToken: legacy ? accessToken : ""))
                            apiKey = ""; accessToken = ""
                        }.disabled(legacy ? appID.isEmpty || accessToken.isEmpty : apiKey.isEmpty)
                        Button("测试连接") { model.testConnection() }.disabled(model.inventory?.credentialConfigured != true)
                        if model.inventory?.credentialConfigured == true { Button("移除钥匙串凭据") { model.removeCredentials() } }
                    }.font(.system(size: 11)).disabled(model.busy)
                }
                if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = model.inventory?.automaticError { Text("上次自动转写未启动：\(error)").font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(.vertical, 5)
        }.frame(height: 530)
            .onAppear { if let settings = model.inventory?.settings { draft = settings } }
            .onChange(of: model.inventory?.settings.models) { previous, _ in if previous == nil, let settings = model.inventory?.settings { draft = settings } }
    }
}
