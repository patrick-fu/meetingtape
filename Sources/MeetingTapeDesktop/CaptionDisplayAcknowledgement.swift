import AppKit
import SwiftUI

struct CaptionDisplayAcknowledgement: NSViewRepresentable {
    let token: String
    let onDisplay: @MainActor (Date, Double) -> Void

    func makeNSView(context: Context) -> DisplayView {
        DisplayView(token: token, onDisplay: onDisplay)
    }

    func updateNSView(_ view: DisplayView, context: Context) {
        view.onDisplay = onDisplay
        if view.token != token {
            view.token = token
            view.needsDisplay = true
        }
    }

    final class DisplayView: NSView {
        var token: String
        var onDisplay: @MainActor (Date, Double) -> Void
        var acknowledgedToken: String?

        init(token: String, onDisplay: @escaping @MainActor (Date, Double) -> Void) {
            self.token = token
            self.onDisplay = onDisplay
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard acknowledgedToken != token, window?.isVisible == true,
                  !visibleRect.intersection(bounds).isEmpty else { return }
            acknowledgedToken = token
            onDisplay(Date(), ProcessInfo.processInfo.systemUptime)
        }
    }
}
