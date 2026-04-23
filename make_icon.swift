#!/usr/bin/swift
import Cocoa

func makeIcon(size: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded rect clip (macOS icon radius ~22.5%)
    let path = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Green gradient background
    let cs = CGColorSpaceCreateDeviceRGB()
    let comps: [CGFloat] = [0.13, 0.70, 0.31, 1,   // top
                             0.04, 0.44, 0.18, 1]   // bottom
    let gradient = CGGradient(colorSpace: cs, colorComponents: comps, locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: size / 2, y: size),
                           end:   CGPoint(x: size / 2, y: 0),
                           options: [])

    // White leaf.fill symbol
    let ptSize = size * 0.56
    let cfg = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .medium)
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let lx = (size - leaf.size.width)  / 2
        let ly = (size - leaf.size.height) / 2
        NSColor.white.set()
        leaf.draw(at: NSPoint(x: lx, y: ly),
                  from: NSRect(origin: .zero, size: leaf.size),
                  operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let iconsetDir = "/tmp/CanopyIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconsetDir,
                                         withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16",       16),  ("icon_16x16@2x",    32),
    ("icon_32x32",       32),  ("icon_32x32@2x",    64),
    ("icon_128x128",    128),  ("icon_128x128@2x", 256),
    ("icon_256x256",    256),  ("icon_256x256@2x", 512),
    ("icon_512x512",    512),  ("icon_512x512@2x",1024),
]

for (name, size) in specs {
    guard let png = makeIcon(size: size) else { print("Failed \(name)"); continue }
    let url = URL(fileURLWithPath: "\(iconsetDir)/\(name).png")
    try! png.write(to: url)
    print("  \(name).png")
}

print("Done — run: iconutil -c icns /tmp/CanopyIcon.iconset -o Sources/Resources/AppIcon.icns")
