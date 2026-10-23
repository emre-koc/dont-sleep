import AppKit

// Renders the open-eyes artwork (Sources/EyeIcon.swift) into an .iconset folder.
// Usage: make-icon <output.iconset>

func render(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 rounded square with a soft drop shadow.
    let inset = side * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: side * 185 / 1024, yRadius: side * 185 / 1024)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = side * 12 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -side * 6 / 1024)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))!.draw(in: shape, angle: -90)

    // Eyes go through their own transparent layer so the cut-out glint shows the tile, not a hole.
    let eyes = EyeIcon.make(open: true)
    let width = tile.width * 0.72
    let height = width * eyes.size.height / eyes.size.width
    let layer = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        eyes.draw(in: rect)
        return true
    }
    layer.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = render(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: out.appendingPathComponent(name))
    }
}
