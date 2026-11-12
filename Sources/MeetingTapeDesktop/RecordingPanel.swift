import AppKit
import SwiftUI
import MeetingTapeTranscription

final class RecordingPanel: NSPanel, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private var currentDisplayID: String?
    private var restoringPosition = false

    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 196, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "MeetingTape 录音悬浮窗"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isFloatingPanel = true; becomesKeyOnlyIfNeeded = true
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = true; isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = PanelHostingView(rootView: RecordingPanelView(model: model, captions: model.liveCaptions))
        setPinned(model.panelPinned)
        delegate = self
        restorePosition()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidMove(_ notification: Notification) {
        guard !restoringPosition, NSEvent.pressedMouseButtons != 0, let screen else { return }
        let id = displayID(screen)
        var positions = UserDefaults.standard.dictionary(forKey: "recordingPanelPositions") as? [String: [String: Double]] ?? [:]
        positions[id] = ["right": screen.visibleFrame.maxX - frame.maxX, "top": screen.visibleFrame.maxY - frame.maxY]
        UserDefaults.standard.set(positions, forKey: "recordingPanelPositions")
        UserDefaults.standard.set(id, forKey: "recordingPanelScreen")
        currentDisplayID = id
    }

    @objc private func screenParametersChanged() {
        restorePosition()
    }

    private func displayID(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) else { return number.stringValue }
        return identifier as String
    }

    private func restorePosition() {
        let preferred = currentDisplayID ?? UserDefaults.standard.string(forKey: "recordingPanelScreen")
        guard let target = NSScreen.screens.first(where: { displayID($0) == preferred }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let id = displayID(target)
        let positions = UserDefaults.standard.dictionary(forKey: "recordingPanelPositions") as? [String: [String: Double]]
        let saved = positions?[id]
        let right = saved?["right"].flatMap { $0.isFinite ? $0 : nil } ?? 32
        let top = saved?["top"].flatMap { $0.isFinite ? $0 : nil } ?? 32
        let origin = NSPoint(x: target.visibleFrame.maxX - frame.width - right,
                             y: target.visibleFrame.maxY - frame.height - top)
        restoringPosition = true
        setFrameOrigin(Self.confinedOrigin(origin, size: frame.size, visibleFrame: target.visibleFrame))
        restoringPosition = false
        currentDisplayID = id
        UserDefaults.standard.set(id, forKey: "recordingPanelScreen")
    }

    static func confinedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: max(visibleFrame.minX + 10, min(origin.x, visibleFrame.maxX - size.width - 10)),
                y: max(visibleFrame.minY + 10, min(origin.y, visibleFrame.maxY - size.height - 10)))
    }

    func setPinned(_ pinned: Bool) {
        let target: NSWindow.Level = pinned ? .floating : .normal
        guard level != target || isFloatingPanel != pinned else { return }
        level = target; isFloatingPanel = pinned
        collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        if pinned && isVisible { orderFrontRegardless() }
    }

    func resize(expanded: Bool, compactHeight: CGFloat) {
        let size = NSSize(width: expanded ? 380 : 196, height: expanded ? 320 : compactHeight)
        guard frame.size != size else { return }
        let origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        setFrame(NSRect(origin: Self.confinedOrigin(origin, size: size, visibleFrame: visible), size: size), display: true, animate: false)
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
    @ObservedObject var captions: LiveCaptionModel
    @State private var following = true
    @State private var hasNewCaptions = false
    private var elapsed: Double { model.snapshot?.elapsedSeconds ?? 0 }
    private var stopping: Bool { model.operation != nil || model.snapshot?.state == .finalizing || model.snapshot?.state == .stopping }
    private var captureIssue: String? {
        guard model.snapshot?.state == .interrupted else { return nil }
        let missing = [("系统音频", model.snapshot?.systemAvailable == true), ("麦克风", model.snapshot?.microphoneAvailable == true)].filter { !$0.1 }.map(\.0)
        return missing.joined(separator: "、") + "中断，正在重连"
    }

    var body: some View {
        Group {
            if model.panelExpanded { expanded } else { compact }
        }
        .frame(width: model.panelExpanded ? 380 : 196, height: model.panelExpanded ? 320 : captions.compactHeight)
        .background(.background.opacity(0.97), in: RoundedRectangle(cornerRadius: model.panelExpanded ? 16 : 12))
        .overlay(RoundedRectangle(cornerRadius: model.panelExpanded ? 16 : 12).stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: model.panelExpanded ? 16 : 12))
        .overlay(alignment: model.panelExpanded ? .bottomLeading : .topLeading) {
            PanelDragRegion().frame(width: model.panelExpanded ? 125 : 100, height: model.panelExpanded ? 40 : 25)
                .padding(.leading, 10).padding(model.panelExpanded ? .bottom : .top, 3)
        }
    }

    private var compact: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(recordingTime(elapsed)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                LiveWave(levels: Array(model.liveLevels.suffix(8))).frame(width: 27, height: 10).accessibilityLabel("录音电平")
                if captions.message != nil || model.snapshot?.state == .interrupted {
                    Circle().fill(.orange).frame(width: 3, height: 3).help(captions.message ?? model.statusText).accessibilityLabel(captions.message ?? model.statusText)
                }
                Spacer(minLength: 0)
                stopButton(size: 20)
                pinButton(size: 20)
                resizeButton(expanded: true, size: 20)
            }.padding(.leading, 10).padding(.trailing, 7).padding(.top, 3).frame(height: 27)
            if captions.anyEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    if let latest = captions.latest { Text(latest.source.name).font(.system(size: 8)).foregroundStyle(.secondary) }
                    if captions.enabled { Text(captions.currentLine).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
                    if captions.translationEnabled { Text(captions.translationLine).font(.system(size: 11)).lineLimit(2).foregroundStyle(.blue.opacity(captions.latest?.translation?.state == .pending ? 0.5 : 1)).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(.red.opacity(0.6)).frame(width: 4, height: 4)
                TextField("新录音", text: $model.activeTitle).font(.system(size: 12, weight: .medium))
                    .textFieldStyle(.plain).disabled(stopping).accessibilityLabel("正在录制的标题")
                Spacer(minLength: 4)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(captions.finalText, forType: .string) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .disabled(captions.finalText.isEmpty).accessibilityLabel("复制已定稿字幕")
                pinButton(size: 24)
                resizeButton(expanded: false, size: 24)
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            if model.snapshot?.state == .failed {
                failure
            } else {
                transcript
                if let captureIssue { Text(captureIssue).font(.system(size: 10)).foregroundStyle(.orange).padding(.horizontal, 16).padding(.vertical, 5) }
                if let message = captions.message {
                    HStack(spacing: 7) {
                        Text(message).lineLimit(2)
                        Spacer(minLength: 2)
                        if captions.anyEnabled { Button("重连") { captions.retry() }.buttonStyle(.plain).disabled(!captions.canRetry).help("从当前录音位置重新连接字幕") }
                    }.font(.system(size: 10)).foregroundStyle(.orange).padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
            HStack(spacing: 9) {
                Text(recordingTime(elapsed)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                LiveWave(levels: Array(model.liveLevels.suffix(8))).frame(width: 40, height: 14).accessibilityLabel("录音电平")
                Spacer(minLength: 0)
                Button { captions.setEnabled(!captions.enabled) } label: { Image(systemName: "captions.bubble").foregroundStyle(captions.enabled ? Color.accentColor : .secondary) }
                    .buttonStyle(.plain).accessibilityLabel(captions.enabled ? "关闭实时转写" : "开启实时转写").help("实时转写")
                Button { captions.setTranslationEnabled(!captions.translationEnabled) } label: { Image(systemName: "translate").foregroundStyle(captions.translationEnabled ? Color.accentColor : .secondary) }
                    .buttonStyle(.plain).accessibilityLabel(captions.translationEnabled ? "关闭字幕翻译" : "开启字幕翻译").help("字幕翻译")
                Button { model.onOpenLibrary?() } label: { Image(systemName: "rectangle.split.2x1").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("打开资料库")
                stopButton(size: 28)
            }.padding(.horizontal, 15).padding(.vertical, 10)
                .overlay(alignment: .top) { Divider().padding(.horizontal, 14) }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(captions.segments) { segment in
                        HStack(alignment: .top, spacing: 9) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recordingTime(segment.start)).monospacedDigit()
                                Text(segment.source.name)
                            }.font(.system(size: 8)).foregroundStyle(.tertiary).frame(width: 43, alignment: .leading).padding(.top, 3)
                            CaptionTextView(segment: segment).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if captions.segments.isEmpty {
                        if captions.anyEnabled {
                            Text(captions.currentLine).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 15)
                        }
                    }
                    if !captions.anyEnabled { Text("录音中").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 18) }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 8)
                    .background(ScrollReadingObserver(following: $following))
            }
            .overlay(alignment: .bottom) {
                if !following {
                    Button(hasNewCaptions ? "有新字幕 · 回到最新" : "回到最新") {
                        hasNewCaptions = false
                        following = true
                        proxy.scrollTo("latest", anchor: .bottom)
                    }
                        .font(.system(size: 10)).buttonStyle(.bordered).padding(.bottom, 6)
                }
            }
            .onChange(of: captions.segments) { _, _ in
                if following { proxy.scrollTo("latest", anchor: .bottom) }
                else { hasNewCaptions = true }
            }
            .onChange(of: following) { _, value in if value { hasNewCaptions = false } }
            .onAppear { following = true; hasNewCaptions = false; proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: captions.sessionID) { _, _ in following = true; hasNewCaptions = false }
        }.frame(maxHeight: .infinity)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.recordingFailureMessage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            if model.recoveryHasTimeline == false {
                Text("没有已提交的录音可恢复。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if model.canRecover { Button("恢复录音") { model.recover() } }
                Button("查看恢复材料") { model.revealRecovery() }
            }.font(.system(size: 11)).disabled(stopping)
            Button("保留材料，继续使用") { model.keepFailedMaterials() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary).disabled(stopping)
        }.padding(.horizontal, 16).frame(maxHeight: .infinity)
    }

    private func pinButton(size: CGFloat) -> some View {
        Button { model.panelPinned.toggle() } label: {
            Image(systemName: model.panelPinned ? "pin.fill" : "pin").font(.system(size: 11))
                .foregroundStyle(model.panelPinned ? Color.accentColor.opacity(0.7) : Color.secondary)
                .frame(width: size, height: size)
                .background(model.panelPinned ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(model.panelPinned ? "取消置顶" : "置顶")
            .accessibilityValue(model.panelPinned ? "已置顶" : "未置顶").help(model.panelPinned ? "取消置顶" : "置顶")
    }

    private func resizeButton(expanded: Bool, size: CGFloat) -> some View {
        Button { model.panelExpanded = expanded; model.onChange?() } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: size, height: size)
        }.buttonStyle(.plain).accessibilityLabel(expanded ? "展开字幕窗" : "收起字幕窗")
    }

    private func stopButton(size: CGFloat) -> some View {
        Button { Task { _ = await model.stop() } } label: {
            Group {
                if stopping { ProgressView().controlSize(.small).scaleEffect(0.5) }
                else { RoundedRectangle(cornerRadius: 2).fill(Color.primary).frame(width: size == 20 ? 7 : 10, height: size == 20 ? 7 : 10) }
            }.frame(width: size, height: size).background(Color.primary.opacity(0.045), in: Circle())
        }.buttonStyle(.plain).disabled(!model.canStop).accessibilityLabel(stopping ? model.statusText : "停止录音")
    }
}

private struct ScrollReadingObserver: NSViewRepresentable {
    @Binding var following: Bool
    final class ObserverView: NSView {
        var changed: ((Bool) -> Void)?
        var isFollowing: (() -> Bool)?
        var monitor: Any?
        private var lastScrollOrigin: CGFloat?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            if let clip = enclosingScrollView?.contentView {
                lastScrollOrigin = clip.bounds.minY
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          let scroll = self.enclosingScrollView else { return }
                    if event.type == .keyDown {
                        guard [115, 116, 119, 121, 125, 126].contains(event.keyCode),
                              let responder = self.window?.firstResponder as? NSView,
                              responder.isDescendant(of: scroll) else { return }
                    } else {
                        guard scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
                    }
                    self.changed?(false)
                    DispatchQueue.main.async { [weak self, weak scroll] in
                        guard let scroll, let document = scroll.documentView else { return }
                        self?.changed?(scroll.contentView.bounds.maxY >= document.bounds.maxY - 24)
                    }
                }
                return event
            }
        }
        @objc private func boundsChanged() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let origin = scroll.contentView.bounds.minY
            let movedUp = lastScrollOrigin.map { origin < $0 - 0.5 } ?? false
            lastScrollOrigin = origin
            guard isFollowing?() == false || NSEvent.pressedMouseButtons != 0 || movedUp else { return }
            changed?(scroll.contentView.bounds.maxY >= document.bounds.maxY - 24)
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            lastScrollOrigin = nil
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        }
    }
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.changed = { following = $0 }
        view.isFollowing = { following }
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.changed = { following = $0 }
        view.isFollowing = { following }
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }
}

private struct LiveWave: View {
    let levels: [Double]
    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let step = size.width / Double(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(2, level * size.height)
                let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: min(3, step - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.secondary.opacity(0.6)))
            }
        }.animation(.easeOut(duration: 0.25), value: levels)
    }
}
