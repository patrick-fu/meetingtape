import MeetingTapeTranscription
import SwiftUI

struct LocalLiveSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var captions: LiveCaptionModel
    @State private var status: LocalLiveStatus?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 5) {
                    Text("SenseVoice 本地字幕").font(.system(size: 20, weight: .semibold))
                    Text("中文、英语、日语、韩语与粤语").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("在设备上识别语音，支持中英混合。首次安装约需 230 MB 模型空间。").font(.system(size: 13))
            if captions.installingLocal || status?.state == "installing" {
                HStack { ProgressView().controlSize(.small); Text(phase).font(.system(size: 12)) }
            }
            if let message = message ?? captions.localInstallationMessage ?? status?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if status?.state == "ready" {
                    Button("重新验证") { install() }.disabled(captions.installingLocal)
                    Button("使用本地字幕") { captions.setRecognitionProvider(.senseVoice); dismiss() }.buttonStyle(.borderedProminent).disabled(captions.installingLocal)
                } else {
                    Button("一键安装") { install() }.buttonStyle(.borderedProminent).disabled(captions.installingLocal || status?.state == "installing")
                }
            }
        }.padding(28).frame(width: 475)
            .task {
                while !Task.isCancelled {
                    do { status = try LocalLiveRuntime().status(); message = nil }
                    catch { message = error.localizedDescription }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    private var phase: String {
        switch status?.phase {
        case "runtime": "正在配置运行环境…"
        case "model": "正在下载模型…"
        case "licenses": "正在准备模型许可…"
        case "verifying": "正在验证模型…"
        default: "正在准备本地字幕…"
        }
    }
    private func install() { Task { await captions.installLocal(); status = try? LocalLiveRuntime().status() } }
}
