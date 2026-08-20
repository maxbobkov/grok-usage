import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Resources/GrokMark.svg")
let pngURL = root.appendingPathComponent("Resources/AppIcon.png")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")
let iconsetURL = root.appendingPathComponent("Resources/AppIcon.iconset")

guard let mark = NSImage(contentsOf: svgURL) else {
    fputs("failed to load \(svgURL.path)\n", stderr)
    exit(1)
}
mark.size = NSSize(width: 24, height: 24)

func renderMaster(size: CGFloat) -> NSBitmapImageRep {
    let scale: CGFloat = 1
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size * scale),
        pixelsHigh: Int(size * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("failed to allocate bitmap\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    NSColor(srgbRed: 0.039, green: 0.039, blue: 0.039, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = size * 0.20
    let markRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    let whiteMark = NSImage(size: markRect.size)
    whiteMark.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    mark.draw(in: NSRect(origin: .zero, size: markRect.size), from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: markRect.size).fill(using: .sourceAtop)
    whiteMark.unlockFocus()
    whiteMark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = renderMaster(size: 1024)
guard let png = master.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}
try png.write(to: pngURL)
print("wrote \(pngURL.path)")

let fm = FileManager.default
try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
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

for (name, px) in sizes {
    let dest = iconsetURL.appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(px)", "\(px)", pngURL.path, "--out", dest.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fputs("sips failed for \(name)\n", stderr)
        exit(1)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetURL.path]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
try? fm.removeItem(at: iconsetURL)
print("wrote \(icnsURL.path)")
