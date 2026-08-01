import AppKit

// Generates AppIcon.iconset (all required sizes), which `iconutil` then
// converts to Resources/AppIcon.icns. See make-app.sh.
//
// Usage: swift Scripts/generate-icon.swift <output-iconset-dir>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fileManager = FileManager.default
try? fileManager.removeItem(atPath: outputDir)
try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> NSData {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)

    // Background: rounded rect (~22.4% corner radius approximates the macOS icon shape)
    let iconPath = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
        xRadius: size * 0.224,
        yRadius: size * 0.224)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.36, green: 0.56, blue: 1.00, alpha: 1.0),
        NSColor(red: 0.18, green: 0.28, blue: 0.92, alpha: 1.0),
    ])!
    gradient.draw(in: iconPath, angle: -90)

    // Glyph: white shipping box, centered
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil),
       let glyph = symbol.withSymbolConfiguration(
           NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .medium)
               .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
        let maxWidth = size * 0.58
        let maxHeight = size * 0.52
        let scale = min(maxWidth / glyph.size.width, maxHeight / glyph.size.height)
        let width = glyph.size.width * scale
        let height = glyph.size.height * scale
        let rect = NSRect(
            x: (size - width) / 2,
            y: (size - height) / 2,
            width: width,
            height: height)
        glyph.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])! as NSData
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in sizes {
    let data = renderIcon(pixels: pixels)
    try data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent(name))
}

print("Iconset written to \(outputDir)")
