import AppKit
import AVFoundation
import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case introduction, permissions, models

    var name: String {
        switch self { case .introduction: "看效果"; case .permissions: "准备录音"; case .models: "选择模型" }
    }
}

@MainActor
final class OnboardingPlayback: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var completion: Task<Void, Never>?

    func toggle() {
        completion?.cancel()
        if playing { player?.pause(); playing = false; return }
        do {
            if player == nil {
                guard let url = Bundle.main.url(forResource: "Welcome", withExtension: "m4a") else {
                    throw DesktopFailure(message: "找不到示例音频。")
                }
                player = try AVAudioPlayer(contentsOf: url)
            }
            guard let player, player.play() else { throw DesktopFailure(message: "示例音频暂时无法播放。") }
            error = nil; playing = true
            let remaining = max(0, player.duration - player.currentTime)
            completion = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) }
                catch { return }
                self?.stop()
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        completion?.cancel(); completion = nil
        player?.stop(); player?.currentTime = 0; playing = false
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: OnboardingPlayback
    var updater: AppUpdater
    @State private var step = OnboardingStep.introduction
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var requestingMicrophone = false

    init(model: AppModel, updater: AppUpdater) {
        self.model = model; self.updater = updater; playback = model.onboardingPlayback
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                    HStack(spacing: 6) {
                        Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20).background(item == step ? Color.accentColor : Color.primary.opacity(0.06), in: Circle())
                            .foregroundStyle(item == step ? Color.white : .secondary)
                        Text(item.name).font(.system(size: 11)).foregroundStyle(item == step ? .primary : .secondary)
                    }.accessibilityElement(children: .combine).accessibilityAddTraits(item == step ? .isSelected : [])
                }
                Spacer(minLength: 0)
                if step != .models { Button("稍后设置") { model.finishOnboarding() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(.horizontal, 30).padding(.top, 23).padding(.bottom, 10)
            if step == .models {
                SettingsView(model: model, updater: updater, onFinish: model.finishOnboarding)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if step == .introduction { introduction } else { permissions }
                    }.frame(maxWidth: 560, alignment: .leading).padding(32).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onChange(of: step) { _, _ in playback.stop() }
        .onDisappear { playback.stop() }
    }

    private var introduction: some View {
        Group {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46)
            Text("让会议，留下来。").font(.system(size: 28, weight: .semibold))
            Text("录音、实时字幕和翻译，在一处完成。").font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("一次产品讨论").font(.system(size: 13, weight: .medium))
                        Text("示例音频").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        guard model.canStart else { return }
                        playback.toggle()
                    } label: {
                        Label(playback.playing ? "暂停示例" : "体验字幕", systemImage: playback.playing ? "pause.fill" : "play.fill")
                    }.controlSize(.large).disabled(!model.canStart)
                }.padding(20).background(Color.primary.opacity(0.03))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let’s keep the recording bar simple. The original sentence comes first, then the translation.")
                        .font(.system(size: 13))
                    Text("录音时，伴随条保持简单就好。先显示原文，再补上译文。")
                        .font(.system(size: 13)).foregroundStyle(Color.accentColor)
                }.padding(20)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
            if let error = playback.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack(spacing: 12) {
                Button("继续") { step = .permissions }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button("直接开始录音") { model.start() }.controlSize(.large).disabled(!model.canStart)
            }
        }
    }

    private var permissions: some View {
        Group {
            Image(systemName: "mic.badge.plus").font(.system(size: 36, weight: .light)).foregroundStyle(Color.accentColor)
            Text("准备录音").font(.system(size: 28, weight: .semibold))
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "mic").frame(width: 24).foregroundStyle(.secondary)
                    Text("麦克风").font(.system(size: 13))
                    Spacer()
                    if microphone == .authorized {
                        Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                    } else if microphone == .restricted {
                        Text("由系统限制").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button(microphone == .notDetermined ? "允许麦克风" : "打开系统设置", action: prepareMicrophone)
                            .disabled(requestingMicrophone)
                    }
                }.padding(20)
                Divider()
                HStack(spacing: 14) {
                    Image(systemName: "speaker.wave.2").frame(width: 24).foregroundStyle(.secondary)
                    Text("系统音频").font(.system(size: 13))
                    Spacer()
                    Text("首次录音时授权").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
            HStack {
                Button("上一步") { step = .introduction }.controlSize(.large)
                Spacer()
                Button("继续") { step = .models }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func prepareMicrophone() {
        guard microphone == .notDetermined else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }
        requestingMicrophone = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            requestingMicrophone = false
        }
    }
}
