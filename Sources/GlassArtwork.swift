import AppKit

/// Shared glass artwork for the app bundle and settings.
enum GlassArtwork {
    static func logo(size: CGFloat, assetURL: URL? = nil) -> NSImage {
        let url = assetURL ?? Bundle.main.url(forResource: "ViveLogo", withExtension: "png")
        guard let url, let source = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        source.size = NSSize(width: size, height: size)
        source.accessibilityDescription = "Floe"
        return source
    }

    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for (index, height) in [4.0, 8.0, 12.0, 8.0, 4.0].enumerated() {
                let path = NSBezierPath(roundedRect: NSRect(x: 1 + Double(index) * 3.5,
                    y: 9 - height / 2, width: 1.6, height: height), xRadius: 0.8, yRadius: 0.8)
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Floe"
        return image
    }
}
