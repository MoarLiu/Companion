import AppKit
import SwiftUI

/// SwiftUI content hosted inside Companion floating panels should receive the first
/// click even when the panel is not already key. Without this, macOS can use
/// the first click only to activate the panel, making visible buttons feel dead.
class CompanionInteractiveHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}
