import AppKit
import SwiftUI

final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 308, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "MeetingTape 录音悬浮窗"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isFloatingPanel = true; becomesKeyOnlyIfNeeded = true
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = true; isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = PanelHostingView(rootView: RecordingPanelView(model: model))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameOrigin(NSPoint(x: frame.maxX - 340, y: frame.maxY - 112))
        }
    }

    func resize(expanded: Bool) {
        let size = NSSize(width: expanded ? 392 : 308, height: expanded ? 310 : 76)
        guard frame.size != size else { return }
        var origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        origin.x = min(max(origin.x, visible.minX + 10), visible.maxX - size.width - 10)
        origin.y = min(max(origin.y, visible.minY + 10), visible.maxY - size.height - 10)
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
}

private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PanelDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct RecordingPanelView: View {
    @ObservedObject var model: AppModel
    private var elapsed: Double { model.snapshot?.elapsedSeconds ?? 0 }
    private var stopping: Bool { model.operation != nil || model.snapshot?.state == .finalizing || model.snapshot?.state == .stopping }

    var body: some View {
        Group {
            if model.panelExpanded { expanded } else { compact }
        }
        .frame(width: model.panelExpanded ? 392 : 308, height: model.panelExpanded ? 310 : 76)
        .background(.background.opacity(0.97), in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(Color.primary.opacity(0.12), lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 25))
        .overlay(alignment: .topLeading) {
            PanelDragRegion().frame(width: model.panelExpanded ? 230 : 146, height: model.panelExpanded ? 32 : 50)
                .padding(.top, model.panelExpanded ? 9 : 13).padding(.leading, 19)
        }
    }

    private var compact: some View {
        HStack(spacing: 15) {
            Text(recordingTime(elapsed)).font(.system(size: 21, weight: .regular)).monospacedDigit().foregroundStyle(model.snapshot?.state == .interrupted ? .orange : Color.secondary)
            LiveWave(levels: Array(model.liveLevels.suffix(10))).frame(width: 51, height: 23).accessibilityLabel("录音电平")
            Spacer(minLength: 0)
            stopButton(width: 43)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 23)
            Button { model.panelExpanded = true; model.onChange?() } label: { Image(systemName: "chevron.down").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24, height: 36) }.buttonStyle(.plain).accessibilityLabel("展开录音悬浮窗")
        }.padding(.horizontal, 19)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 15) {
                Spacer()
                Button { model.onOpenLibrary?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 27) }.buttonStyle(.plain).accessibilityLabel("打开资料库")
                Button { model.panelExpanded = false; model.onChange?() } label: { Image(systemName: "chevron.up").frame(width: 24, height: 27) }.buttonStyle(.plain).accessibilityLabel("收起录音悬浮窗")
            }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 14).padding(.trailing, 19)
            TextField("新录音", text: $model.activeTitle).font(.system(size: 22, weight: .medium)).textFieldStyle(.plain).padding(.horizontal, 30).padding(.top, 10).disabled(stopping).accessibilityLabel("正在录制的标题")
            if model.snapshot?.state == .failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.errorMessage ?? model.snapshot?.failureReason ?? model.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    HStack { Button("恢复录音") { model.recover() }; Button("查看恢复材料") { model.revealRecovery() } }.font(.system(size: 11)).disabled(stopping)
                    Button("保留材料，继续使用") { model.keepFailedMaterials() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary).disabled(stopping)
                }.padding(.horizontal, 30).frame(maxHeight: .infinity)
            } else {
                LiveWave(levels: model.liveLevels).frame(height: 62).padding(.horizontal, 30).padding(.top, 27)
                HStack(spacing: 18) {
                    source("系统音频", available: model.snapshot?.systemAvailable ?? false)
                    source("麦克风", available: model.snapshot?.microphoneAvailable ?? false)
                }.padding(.horizontal, 30).padding(.top, 16)
                if model.snapshot?.state == .interrupted {
                    Text(model.statusText).font(.system(size: 10)).foregroundStyle(.orange).padding(.leading, 30).padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(recordingTime(elapsed)).font(.system(size: 22)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                stopButton(width: 86)
            }.padding(.horizontal, 30).padding(.bottom, 22)
        }
    }

    private func source(_ title: String, available: Bool) -> some View {
        HStack(spacing: 6) { Circle().fill(available ? Color.green.opacity(0.65) : .orange).frame(width: 4, height: 4); Text(title).foregroundStyle(.secondary) }.font(.system(size: 10))
    }

    private func stopButton(width: CGFloat) -> some View {
        Button { Task { _ = await model.stop() } } label: {
            Group {
                if stopping { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { RoundedRectangle(cornerRadius: 3.5).fill(Color.primary).frame(width: 15, height: 15) }
            }.frame(width: width, height: 43).background(Color.primary.opacity(0.045), in: Capsule())
        }.buttonStyle(.plain).disabled(!model.canStop).accessibilityLabel(stopping ? model.statusText : "停止录音")
    }
}

private struct LiveWave: View {
    let levels: [Double]
    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let step = size.width / Double(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(4, level * size.height)
                let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: min(3, step - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.secondary.opacity(0.6)))
            }
        }.animation(.easeOut(duration: 0.25), value: levels)
    }
}
