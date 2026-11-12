import AppKit
import Combine
import MeetingTapeTranscription
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var name: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "system") ?? .system }
    @MainActor func apply() {
        NSApp.appearance = self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, models, captions, minutes, terms, storage, about
    var id: Self { self }
    var name: String {
        switch self { case .general: "通用"; case .recording: "录音"; case .models: "模型"; case .captions: "实时字幕"; case .minutes: "会议纪要"; case .terms: "术语"; case .storage: "存储与导出"; case .about: "关于" }
    }
    var symbol: String {
        switch self { case .general: "desktopcomputer"; case .recording: "mic"; case .models: "square.3.layers.3d"; case .captions: "captions.bubble"; case .minutes: "note.text"; case .terms: "character.book.closed"; case .storage: "folder"; case .about: "info.circle" }
    }
}

@MainActor
final class SettingsPreferences: ObservableObject {
    @Published var draft = TranscriptionSettings()
    @Published private(set) var loaded = false
    @Published var dirty = false
    @Published var multipleModels = false
    private var inventorySubscription: AnyCancellable?

    init(transcription: TranscriptionModel) {
        inventorySubscription = transcription.$inventory.sink { [weak self] inventory in
            guard let self, let inventory, !dirty else { return }
            let modelsChanged = !loaded || draft.models != inventory.settings.models
            draft = inventory.settings; loaded = true
            if modelsChanged { multipleModels = draft.models.count > 1 }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var transcription: TranscriptionModel
    @ObservedObject private var captions: LiveCaptionModel
    @ObservedObject private var updater: AppUpdater
    @ObservedObject private var preferences: SettingsPreferences
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("exportIncludesVersions") private var exportIncludesVersions = false
    private var section: SettingsSection {
        get { onFinish == nil ? model.settingsSection : .models }
        nonmutating set { model.settingsSection = newValue }
    }
    @State private var choosingPostModel = false
    @State private var connecting = false
    @State private var localModel: TranscriptModel?
    @State private var languages = false
    @State private var localLive = false
    private let onFinish: (() -> Void)?

    init(model: AppModel, updater: AppUpdater, onFinish: (() -> Void)? = nil) {
        self.model = model; transcription = model.transcription; captions = model.liveCaptions; self.updater = updater
        preferences = model.settingsPreferences
        self.onFinish = onFinish
    }

    private var editable: Bool { preferences.loaded && !transcription.busy && !transcription.updating }

    var body: some View {
        HStack(spacing: 0) {
            if onFinish == nil { sidebar; Divider() }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Text(onFinish == nil ? section.name : "选择模型").font(.system(size: 24, weight: .semibold))
                            Spacer()
                            if let inventory = transcription.inventory {
                                Label("\(inventory.memoryGiB) GB 内存", systemImage: "desktopcomputer").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.bottom, 5)
                        switch section {
                        case .general: general
                        case .recording: recording
                        case .models: models
                        case .captions: subtitleSettings
                        case .minutes: TextModelSettingsView()
                        case .terms:
                            ConfirmedTermsView(sessionID: nil)
                            Text("豆包翻译使用已确认译名；Apple 本地翻译沿用系统结果。").font(.system(size: 11)).foregroundStyle(.secondary)
                        case .storage: storage
                        case .about: about
                        }
                    }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: onFinish == nil ? 800 : 0, minHeight: onFinish == nil ? 560 : 0)
        .onChange(of: appearance) { _, value in value.apply() }
        .sheet(isPresented: $connecting) { CloudConnectionSettingsView(model: transcription) }
        .sheet(item: $localModel) { family in LocalModelSettingsView(model: transcription, family: family) }
        .sheet(isPresented: $languages) {
            VStack(alignment: .leading, spacing: 18) {
                Text("翻译语言包").font(.system(size: 18, weight: .semibold))
                if #available(macOS 26, *) { LocalTranslationSetup(target: captions.targetLanguage).id(captions.targetLanguage) }
                else { Text("本地实时翻译需要 macOS 26。").foregroundStyle(.secondary) }
                HStack { Spacer(); Button("完成") { languages = false }.keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 430)
        }
        .sheet(isPresented: $localLive) { LocalLiveSettingsView(captions: captions) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
                Text("MeetingTape").font(.system(size: 14, weight: .semibold))
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 27)
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Label(item.name, systemImage: item.symbol)
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                        .foregroundStyle(section == item ? Color.accentColor : Color.primary.opacity(0.75))
                        .background(section == item ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.horizontal, 11).accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
        }.frame(width: 190).background(Color(nsColor: .windowBackgroundColor))
    }

    private var general: some View {
        group {
            settingRow("外观") {
                Picker("外观", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.name).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 255)
            }
            Divider()
            settingRow("使用入门") {
                Button("查看引导") { model.showOnboarding(); model.onOpenLibrary?() }.disabled(!model.canStart)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 20) {
            group {
                settingRow("保存位置", detail: model.outputDirectory) { Button("更改…") { model.chooseDirectory() }.disabled(model.active || model.operation != nil) }
                Divider()
                settingRow("保留原始麦克风音轨") {
                    Toggle("保留原始麦克风音轨", isOn: Binding(get: { model.keepRaw }, set: { model.setKeepRaw($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.active || model.operation != nil)
                }
                Divider()
                settingRow("音源识别", detail: preferences.draft.recognitionMode == .separate ? "系统音频与麦克风分别识别，保留来源" : "合并成一路识别，节省转写资源") {
                    Picker("音源识别", selection: preference(\.recognitionMode)) {
                        Text("分开转写").tag(RecognitionMode.separate); Text("合并转写").tag(RecognitionMode.merged)
                    }.labelsHidden().frame(width: 150).disabled(!editable)
                }
                Divider()
                settingRow("录音结束后自动转写") {
                    Toggle("录音结束后自动转写", isOn: preference(\.automatic)).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!editable)
                }
            }
            if preferences.draft.automatic && preferences.draft.models.contains(.doubao) {
                Text("新录音保存完成后会上传至豆包，使用你的账户计费。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if model.retainedRecoveryPath != nil { Button("查看上次恢复材料") { model.revealRecovery() } }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 23) {
            group {
                defaultRow("实时转写", symbol: "waveform", color: .indigo, detail: "录音时显示原文") {
                    Menu {
                        ForEach(LiveRecognitionProvider.allCases) { provider in
                            Button(provider.name) { captions.setRecognitionProvider(provider) }
                        }
                        Divider()
                        Button("配置本地字幕…") { localLive = true }
                        Button("配置豆包连接…") { connecting = true }
                    } label: { modelLabel(captions.recognitionProvider.name, ready: captions.recognitionProvider == .senseVoice ? (try? LocalLiveRuntime().installation()) != nil : transcription.inventory?.credentialConfigured == true) }.menuStyle(.borderlessButton).frame(width: 205)
                }
                Divider()
                defaultRow("录后转写", symbol: "doc.text", color: .green, detail: "录音结束后生成完整稿件") {
                    Button { choosingPostModel = true } label: {
                        HStack { modelLabel(preferences.draft.models.map(\.name).joined(separator: " + "), ready: preferences.draft.models.allSatisfy(modelReady)); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    }.disabled(!editable).popover(isPresented: $choosingPostModel) { postModels }
                }
                HStack(spacing: 15) {
                    Toggle("多模型对照", isOn: Binding(get: { preferences.multipleModels }, set: { value in
                        preferences.multipleModels = value
                        if !value, preferences.draft.models.count > 1 { preferences.draft.models = [preferences.draft.models[0]]; preferences.dirty = true }
                    })).toggleStyle(.checkbox)
                    if preferences.draft.models.count > 1 {
                        Picker("主稿优先", selection: Binding(get: { preferences.draft.models.first ?? .qwen }, set: { value in
                            preferences.draft.models.removeAll { $0 == value }; preferences.draft.models.insert(value, at: 0); preferences.dirty = true
                        })) { ForEach(preferences.draft.models) { Text($0.name).tag($0) } }.frame(maxWidth: 220)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).padding(.leading, 49).padding(.bottom, 10).disabled(!editable)
                Divider()
                defaultRow("字幕翻译", symbol: "character.bubble", color: .orange, detail: "将字幕译成目标语言") {
                    Picker("字幕翻译模型", selection: Binding(get: { captions.provider }, set: { captions.setProvider($0) })) {
                        ForEach(SubtitleTranslationProvider.allCases) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 205)
                }
                Divider()
                defaultRow("会议纪要", symbol: "note.text", color: .purple, detail: "整理会议内容") {
                    Button("配置模型…") { section = .minutes }
                }
            }
            HStack { Text("模型与连接").font(.system(size: 13, weight: .semibold)); Spacer(); Button("查找已有模型…") { transcription.discoverExisting() }.font(.system(size: 11)).disabled(transcription.updating) }
            HStack(alignment: .top, spacing: 14) {
                localModelsCard
                cloudCard
            }
            group {
                settingRow("Apple 本地翻译", detail: "使用系统语言包") { Button("管理语言…") { languages = true } }
            }
            if let error = transcription.inventory?.automaticError {
                Text("上次自动转写未启动：\(error)").font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var postModels: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("录后转写模型").font(.system(size: 14, weight: .semibold))
            ForEach(TranscriptModel.allCases) { family in
                HStack(spacing: 12) {
                    if preferences.multipleModels {
                        Toggle(family.name, isOn: Binding(get: { preferences.draft.models.contains(family) }, set: { value in
                            if value { preferences.draft.models.append(family) }
                            else { preferences.draft.models.removeAll { $0 == family } }
                            preferences.dirty = true
                        })).toggleStyle(.checkbox).disabled((!modelReady(family) && !preferences.draft.models.contains(family)) || preferences.draft.models == [family])
                    } else {
                        Button {
                            preferences.draft.models = [family]; preferences.dirty = true; choosingPostModel = false
                        } label: { Label(family.name, systemImage: preferences.draft.models.contains(family) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain).disabled(!modelReady(family))
                    }
                    Spacer()
                    if !modelReady(family) {
                        Button(family.local ? "安装…" : "配置…") {
                            choosingPostModel = false
                            if family.local { localModel = family } else { connecting = true }
                        }.font(.system(size: 11))
                    }
                }
            }
            if preferences.multipleModels { Text("每个模型保留独立稿件。").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 310).disabled(!editable)
    }

    private var localModelsCard: some View {
        group {
            Label("本地转写", systemImage: "desktopcomputer").font(.system(size: 13, weight: .semibold)).padding(.bottom, 12)
            ForEach(TranscriptModel.allCases.filter(\.local)) { family in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(family.name).font(.system(size: 12))
                        Text(localStatus(family)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(modelReady(family) ? "管理…" : "安装…") { localModel = family }.font(.system(size: 11))
                }.padding(.vertical, 7)
            }
            Divider().padding(.vertical, 7)
            if let inventory = transcription.inventory {
                Text(inventory.localSupported ? "为这台 Mac 推荐 \(inventory.recommendedProfile == "standard" ? "标准 · 8-bit" : "节省内存 · 4-bit")" : "本地模型需 Apple Silicon 与至少 16 GB 内存")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cloudCard: some View {
        group {
            Label("豆包 · 火山引擎", systemImage: "cloud").font(.system(size: 13, weight: .semibold)).padding(.bottom, 12)
            connectionStatus
            Text("实时转写 / 录后转写 / 翻译").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 7)
            Text("自备 API Key，按账户用量计费").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
            Divider().padding(.vertical, 9)
            HStack { Spacer(); Button(transcription.inventory?.credentialConfigured == true ? "管理连接…" : "配置连接…") { connecting = true } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionStatus: some View {
        Label(transcription.inventory?.credentialConfigured == true ? "已配置" : "未配置", systemImage: "circle.fill")
            .font(.system(size: 11)).foregroundStyle(transcription.inventory?.credentialConfigured == true ? .green : .orange)
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            group {
                settingRow("语音识别模型") {
                    Picker("语音识别模型", selection: Binding(get: { captions.recognitionProvider }, set: { captions.setRecognitionProvider($0) })) {
                        ForEach(LiveRecognitionProvider.allCases) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 205)
                }
                Divider()
                settingRow("实时转写") { Toggle("实时转写", isOn: Binding(get: { captions.enabled }, set: { captions.setEnabled($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider()
                settingRow("字幕翻译") { Toggle("字幕翻译", isOn: Binding(get: { captions.translationEnabled }, set: { captions.setTranslationEnabled($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider()
                settingRow("目标语言", detail: "已经是目标语言时无需翻译") {
                    Picker("目标语言", selection: Binding(get: { captions.targetLanguage }, set: { captions.setTargetLanguage($0) })) {
                        ForEach(SubtitleLanguage.identifiers, id: \.self) { Text(SubtitleLanguage.name($0)).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                Divider()
                settingRow("悬浮窗置顶") { Toggle("悬浮窗置顶", isOn: $model.panelPinned).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            }
            if captions.recognitionProvider == .senseVoice { Button("配置本地字幕…") { localLive = true } }
            if captions.anyEnabled, captions.recognitionProvider == .doubao { Text("实时语音识别会上传声音至豆包，使用你的账户计费。").font(.system(size: 11)).foregroundStyle(.orange) }
            if captions.provider == .local {
                if #available(macOS 26, *) { LocalTranslationSetup(target: captions.targetLanguage).id(captions.targetLanguage) }
                else { Text("本地实时翻译需要 macOS 26，可在模型页选择豆包翻译。").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else { Text("文字翻译使用豆包，需开通 volc.speech.mt。").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private var storage: some View {
        group {
            settingRow("录音文件", detail: model.outputDirectory) { Button("打开文件夹") { NSWorkspace.shared.open(URL(fileURLWithPath: model.outputDirectory)) } }
            Divider()
            settingRow("Markdown 默认附加其他版本") { Toggle("Markdown 默认附加其他版本", isOn: $exportIncludesVersions).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            Divider()
            settingRow("运行明细", detail: "耗时与资源观测随稿件折叠附加") { Text("Markdown").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 17) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 6) {
                    Text("MeetingTape").font(.system(size: 22, weight: .semibold))
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查更新…") { updater.checkForUpdates(nil) }.disabled(!updater.canCheck)
            }
            group {
                settingRow("自动更新") { Toggle("自动更新", isOn: Binding(get: { updater.automaticallyUpdates }, set: { updater.setAutomaticUpdates($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!updater.available) }
                Divider()
                settingRow("开源项目") { Link("GitHub ↗", destination: URL(string: "https://github.com/patrick-fu/meetingtape")!) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let message = transcription.message {
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 10)
                    Button { transcription.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭设置提示")
                }
            }
            if preferences.dirty || transcription.busy || onFinish != nil {
                HStack {
                    if transcription.busy { ProgressView().controlSize(.small) }
                    else if preferences.dirty { Text("有未保存的更改").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    if let onFinish {
                        Button(preferences.dirty ? "保存并进入资料库" : "进入资料库") {
                            if preferences.dirty { transcription.save(preferences.draft) { passed in if passed { preferences.dirty = false; onFinish() } } }
                            else { onFinish() }
                        }.keyboardShortcut(.defaultAction).disabled(transcription.busy || transcription.updating || (preferences.dirty && !editable))
                    } else {
                        Button("保存偏好") {
                            transcription.save(preferences.draft) { passed in if passed { preferences.dirty = false } }
                        }.keyboardShortcut("s", modifiers: .command).disabled(!preferences.dirty || !editable)
                    }
                }
            }
        }.padding(.horizontal, 28).padding(.vertical, preferences.dirty || transcription.busy || transcription.message != nil || onFinish != nil ? 14 : 0)
    }

    private func preference<Value>(_ key: WritableKeyPath<TranscriptionSettings, Value>) -> Binding<Value> {
        Binding(get: { preferences.draft[keyPath: key] }, set: { preferences.draft[keyPath: key] = $0; preferences.dirty = true })
    }
    private func modelReady(_ family: TranscriptModel) -> Bool {
        family.local ? transcription.inventory?.settings.installations[family.rawValue]?.available == true : transcription.inventory?.credentialConfigured == true
    }
    private func localStatus(_ family: TranscriptModel) -> String {
        if let status = transcription.inventory?.installations.first(where: { $0.model == family }), ["installing", "validating", "failed"].contains(status.state) { return status.message }
        guard let installation = transcription.inventory?.settings.installations[family.rawValue], installation.available else { return "未安装" }
        return installation.profile == "standard" ? "8-bit · 已就绪" : "4-bit · 已就绪"
    }
    private func modelLabel(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 7) { Circle().fill(ready ? .green.opacity(0.7) : .orange.opacity(0.75)).frame(width: 5, height: 5); Text(title).font(.system(size: 11)).lineLimit(2); Spacer(minLength: 0) }
    }
    private func defaultRow<Control: View>(_ title: String, symbol: String, color: Color, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(color).frame(width: 35, height: 35).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            control().frame(maxWidth: 205)
        }.padding(.vertical, 10)
    }
    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12)); if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) } }
            Spacer(minLength: 5)
            control()
        }.padding(.vertical, 9)
    }
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content).padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.09)))
    }
}

private struct CloudConnectionSettingsView: View {
    @ObservedObject var model: TranscriptionModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var legacy = false
    @State private var apiKey = ""
    @State private var appID = ""
    @State private var accessToken = ""
    private var configured: Bool { model.inventory?.credentialConfigured == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Label("豆包 · 火山引擎", systemImage: "cloud").font(.system(size: 18, weight: .semibold))
            if configured && !editing {
                Label(model.fileConnectionVerified ? "文件转写连接已验证" : "凭据已配置", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("实时转写与字幕翻译需分别开通服务。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Button("测试文件转写连接") { model.testConnection() }; Button("更新 Key…") { editing = true } }.disabled(model.busy || model.updating)
                Button("移除钥匙串凭据", role: .destructive) { model.removeCredentials() }.font(.system(size: 11)).disabled(model.busy || model.updating)
            } else {
                Picker("接入版本", selection: $legacy) { Text("API Key").tag(false); Text("旧版凭据").tag(true) }.pickerStyle(.segmented).disabled(model.busy || model.updating)
                if legacy { TextField("App ID", text: $appID).disabled(model.busy || model.updating); SecureField("Access Token", text: $accessToken).disabled(model.busy || model.updating) }
                else { SecureField("API Key", text: $apiKey).disabled(model.busy || model.updating) }
                HStack { Label("保存至系统钥匙串", systemImage: "lock"); Spacer(); Link("获取 Key ↗", destination: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!) }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text("发送 1 秒静音测试，验证通过后再保存凭据。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(configured && !editing ? "完成" : "取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if !configured || editing {
                    Button("测试并保存") {
                        let value = DoubaoCredential(apiKey: legacy ? "" : apiKey.trimmingCharacters(in: .whitespacesAndNewlines), appID: legacy ? appID.trimmingCharacters(in: .whitespacesAndNewlines) : "", accessToken: legacy ? accessToken.trimmingCharacters(in: .whitespacesAndNewlines) : "")
                        model.connect(value) { saved in if saved { apiKey = ""; appID = ""; accessToken = ""; editing = false } }
                    }.keyboardShortcut(.defaultAction).disabled(model.busy || model.updating || (legacy ? appID.isEmpty || accessToken.isEmpty : apiKey.isEmpty))
                }
            }
        }.textFieldStyle(.roundedBorder).padding(27).frame(width: 470).interactiveDismissDisabled(model.busy)
            .onDisappear { apiKey = ""; appID = ""; accessToken = "" }
    }
}

private struct LocalModelSettingsView: View {
    @ObservedObject var model: TranscriptionModel
    let family: TranscriptModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile = "low-memory"
    private var installation: LocalInstallation? { model.inventory?.settings.installations[family.rawValue] }
    private var status: ModelInstallationStatus? { model.inventory?.installations.first { $0.model == family } }
    private var installing: Bool { model.inventory?.installations.contains { ["installing", "validating"].contains($0.state) } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(family.name, systemImage: "desktopcomputer").font(.system(size: 18, weight: .semibold))
            if let inventory = model.inventory {
                Text("\(inventory.memoryGiB) GB 内存 · 推荐\(inventory.recommendedProfile == "standard" ? "标准版" : "节省内存版")").font(.system(size: 11)).foregroundStyle(.secondary)
                if installation?.available == true { Label("已安装 \(installation?.profile == "standard" ? "8-bit" : "4-bit")", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green) }
                Picker("模型版本", selection: $profile) { Text("节省内存 · 4-bit").tag("low-memory"); Text("标准 · 8-bit").tag("standard") }.pickerStyle(.segmented)
                Text("首次完整安装约下载 \(profile == "standard" ? "6" : "4.5") GB，需要 \(profile == "standard" ? "12" : "10") GB 可用空间。").font(.system(size: 11)).foregroundStyle(.secondary)
                if let status {
                    HStack { if ["installing", "validating"].contains(status.state) { ProgressView().controlSize(.small) }; Text(status.message).font(.system(size: 11)).textSelection(.enabled) }
                }
                if !inventory.localSupported { Text("本地模型需要 Apple Silicon 和至少 16 GB 内存。").font(.system(size: 11)).foregroundStyle(.orange) }
            } else { ProgressView().controlSize(.small) }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("查找已有模型…") { model.discoverExisting() }.disabled(model.updating)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                if model.existingModels[family.rawValue] != nil {
                    Button("使用已有模型") { model.install(family, profile: profile, reuse: true) }.disabled(unavailable)
                }
                Button(installation?.available == true ? "安装所选版本" : "安装模型") { model.install(family, profile: profile, reuse: false) }.disabled(unavailable)
            }
        }.padding(27).frame(width: 500)
            .onAppear { profile = installation?.profile ?? model.inventory?.recommendedProfile ?? "low-memory" }
    }
    private var unavailable: Bool { model.inventory?.localSupported != true || installing || model.busy || model.updating }
}
