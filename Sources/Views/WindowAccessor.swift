import SwiftUI
import AppKit

/// Hands the enclosing `NSWindow` back to SwiftUI code so we can resize, center, or
/// close it programmatically. Drop into `.background(WindowAccessor { window in ... })`.
/// The closure fires once the view's window is attached, and again if the window changes.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let w = view.window { onAttach(w) }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onAttach(w) }
        }
    }
}

extension View {
    /// Resizes the enclosing NSWindow to the given content size and recenters it.
    /// Animated for visual continuity — handshake feels like a smooth grow/shrink.
    func resizeWindow(to size: CGSize, animated: Bool = true) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        var frame = w.frame
        let oldContent = w.contentRect(forFrameRect: frame).size
        let dW = size.width  - oldContent.width
        let dH = size.height - oldContent.height
        // Keep the window's top-left corner anchored
        frame.origin.y    -= dH
        frame.size.width  += dW
        frame.size.height += dH
        if animated {
            w.animator().setFrame(frame, display: true, animate: true)
        } else {
            w.setFrame(frame, display: true)
        }
    }
}
