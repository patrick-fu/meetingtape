import AppKit
import SwiftUI

@main
struct DesktopMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = DesktopDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class DesktopDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var libraryWindow: NSWindow!
    private var recordingPanel: RecordingPanel!
    private var statusItem: NSStatusItem!
    private var recordMenuItem: NSMenuItem!
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MeetingTape"
        window.minSize = NSSize(width: 820, height: 600)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MeetingTapeLibrary")
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.center()
        libraryWindow = window
        recordingPanel = RecordingPanel(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MeetingTape")
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        statusMenu.addItem(withTitle: "打开资料库", action: #selector(showLibrary), keyEquivalent: "").target = self
        recordMenuItem = statusMenu.addItem(withTitle: "开始录音", action: #selector(toggleRecording), keyEquivalent: "")
        recordMenuItem.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出 MeetingTape", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = statusMenu
        model.onChange = { [weak self] in self?.updateWindows() }
        model.onOpenLibrary = { [weak self] in self?.showLibrary() }
        configureMenu()
        updateWindows()
        showLibrary()
        model.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showLibrary(); return true }

    @objc private func showLibrary() {
        libraryWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.panelVisible { recordingPanel.orderFrontRegardless() }
    }

    private func updateWindows() {
        recordingPanel.resize(expanded: model.panelExpanded)
        if model.panelVisible { recordingPanel.orderFrontRegardless() } else { recordingPanel.orderOut(nil) }
        statusItem.button?.title = model.active ? " " + recordingTime(model.snapshot?.elapsedSeconds ?? 0) : ""
        recordMenuItem.title = model.active ? "停止录音" : "开始录音"
        recordMenuItem.isEnabled = model.active ? model.canStop : model.canStart
    }

    @objc private func toggleRecording() {
        if model.active { Task { _ = await model.stop() } } else { model.start() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateCancel }
        if model.operation != nil || model.snapshot?.state == .finalizing || model.snapshot?.state == .stopping {
            let alert = NSAlert()
            alert.messageText = model.statusText
            alert.informativeText = "完成后即可退出。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return .terminateCancel
        }
        if model.active {
            let alert = NSAlert()
            alert.messageText = "录音仍在进行"
            alert.informativeText = "关闭资料库不会停止录音。"
            alert.addButton(withTitle: "停止并退出")
            alert.addButton(withTitle: "继续录音并退出")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                terminationPending = true
                Task {
                    let stopped = await model.stop()
                    await model.flush()
                    terminationPending = false
                    sender.reply(toApplicationShouldTerminate: stopped)
                }
                return .terminateLater
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        terminationPending = true
        Task { await model.flush(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func configureMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MeetingTape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MeetingTape", action: #selector(quit), keyEquivalent: "q").target = self
        let root = NSMenuItem(); root.submenu = appMenu; main.addItem(root)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editRoot = NSMenuItem(); editRoot.submenu = edit; main.addItem(editRoot)
        let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "资料库", action: #selector(showLibrary), keyEquivalent: "1").target = self
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        let windowRoot = NSMenuItem(); windowRoot.submenu = windows; main.addItem(windowRoot)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
}
