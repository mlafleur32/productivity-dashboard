// Demo/DemoWindowSizer.swift
//
// Demo mode only: opens the dashboard window at one predictable size, so
// screenshots and recordings show the Assistant's summary and the first
// plan rows without scrolling. A saved window frame would otherwise win
// over the Scene's defaultSize. Touches only this app's own window.

import AppKit
import SwiftUI

struct DemoWindowSizer: NSViewRepresentable {
    /// Largest size used; smaller screens get their visible area instead.
    var maxSize = CGSize(width: 1280, height: 1000)

    func makeNSView(context: Context) -> NSView { SizingView(maxSize: maxSize) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SizingView: NSView {
        let maxSize: CGSize
        private var didSize = false

        init(maxSize: CGSize) {
            self.maxSize = maxSize
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didSize, let window else { return }
            didSize = true
            // After the current layout pass, so AppKit isn't mid-layout.
            DispatchQueue.main.async {
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                let size = CGSize(width: min(self.maxSize.width, visible.width),
                                  height: min(self.maxSize.height, visible.height))
                let origin = CGPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - size.height)
                window.setFrame(CGRect(origin: origin, size: size), display: true)
            }
        }
    }
}
