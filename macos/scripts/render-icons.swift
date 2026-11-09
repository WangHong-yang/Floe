import AppKit

@main
struct RenderIcons {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let image = GlassArtwork.logo(size: CGFloat(pixels), assetURL: URL(fileURLWithPath: CommandLine.arguments[2]))
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                    pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                let side = CGFloat(pixels)
                let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.055, y: side * 0.055,
                    width: side * 0.89, height: side * 0.89),
                    xRadius: side * 0.20, yRadius: side * 0.20)
                NSColor.black.setFill()
                tile.fill()
                tile.addClip()
                // Keep the complete sculpture inside the black tile.
                image.draw(in: NSRect(x: side * 0.02, y: side * 0.02,
                    width: side * 0.96, height: side * 0.96))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
