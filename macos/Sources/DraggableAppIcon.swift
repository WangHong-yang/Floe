import AppKit
import SwiftUI

/// Drag the actual running .app bundle as a Finder-compatible file URL.
/// A picture-only drag cannot be added to macOS privacy permission lists.
struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView()
        view.image = GlassArtwork.logo(size: 52)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.toolTip = "Drag into Input Monitoring or Accessibility to add Floe"
        view.setAccessibilityLabel("Floe app icon. Drag into System Settings to grant permissions.")
        return view
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

final class AppIconDragView: NSImageView, NSDraggingSource {
    private var dragging = false
    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Keep the mouse sequence here so mouseDragged can start a file drag.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        item.setDraggingFrame(bounds, contents: icon)
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
    }
}
