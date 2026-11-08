import MeetingTapeTranscription
import SwiftUI

struct TextModelSettingsView: View {
    @State private var settings = TextModelSettings()
    @State private var key = ""
    @State private var message: String?
    @State private var busy = false
    @State private var loaded = false

    private var connection: Binding<TextModelConnection> {
        Binding(get: { settings.connection }, set: { if settings.provider == .local { settings.local = $0 } else { settings.cloud = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("转写完成后自动生成纪要", isOn: $settings.automatic)
                Picker("生成语言", selection: $settings.language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }.frame(maxWidth: 300)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 16) {
                Picker("纪要模型", selection: $settings.provider) {
                    ForEach(TextModelLocation.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented)
                LabeledContent("API 地址") { TextField("API 地址", text: connection.baseURL).textFieldStyle(.roundedBorder) }
                LabeledContent("模型") { TextField("模型名称", text: connection.model).textFieldStyle(.roundedBorder) }
                if settings.provider == .cloud {
                    LabeledContent("API Key") { SecureField("保存到钥匙串", text: $key).textFieldStyle(.roundedBorder) }
                    HStack {
                        Link("获取火山方舟 API Key", destination: URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")!)
                        Spacer()
                        Button("移除 API Key") {
                            do { try TextModelCredentials.remove(connection: settings.cloud); message = "已移除这个地址的 API Key。" }
                            catch { message = error.localizedDescription }
                        }
                    }.font(.system(size: 11))
                }
            }.padding(20).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            HStack {
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("测试连接") { test() }.disabled(busy || !loaded || !settings.configured)
                Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(busy || !loaded)
            }
        }.disabled(!loaded)
            .task {
                do { settings = try TextModelConfiguration().load(); loaded = true }
                catch { message = error.localizedDescription }
            }
            .onChange(of: settings.provider) { _, _ in key = ""; message = nil }
    }

    private func save() {
        do {
            if settings.provider == .cloud, !key.isEmpty { try TextModelCredentials.save(key, connection: settings.cloud) }
            try TextModelConfiguration().save(settings)
            key = ""; message = "纪要偏好已保存。"
        } catch { message = error.localizedDescription }
    }

    private func test() {
        busy = true; message = nil
        let settings = settings, key = key.isEmpty ? nil : key
        Task {
            do {
                _ = try await TextModelClient.generate(system: "Reply with ready.", user: "Connection test.", settings: settings, key: key, maxTokens: 16)
                message = "连接成功。"
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
