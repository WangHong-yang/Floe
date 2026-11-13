import AppKit

/// Shared glass artwork for the app bundle and settings.
enum GlassArtwork {
    static func logo(size: CGFloat, assetURL: URL? = nil) -> NSImage {
        let url = assetURL ?? Bundle.main.url(forResource: "FloeLogo", withExtension: "png")
        guard let url, let source = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        source.size = NSSize(width: size, height: size)
        source.accessibilityDescription = "Floe"
        return source
    }

    static func menuIcon() -> NSImage {
        statusArtwork
    }

    private static let statusArtwork: NSImage = {
        let source = Bundle.main.url(forResource: "FloeMenuIcon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { _ in
            guard let source else { return false }
            let height = min(16, 28 * source.size.height / source.size.width)
            source.draw(in: NSRect(x: 0, y: (18 - height) / 2, width: 28, height: height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Floe"
        return image
    }()
}
