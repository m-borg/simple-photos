import AppKit
import CoreGraphics
import Foundation

func drawIcon(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(size)
    let inset = s * 0.08
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = cardRect.width * 0.225

    // Squircle clipping path
    let path = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Background rich gradient
    if let bgGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.16, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.34, alpha: 1.0),
        NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.44, alpha: 1.0)
    ]) {
        bgGrad.draw(in: cardRect, angle: -55)
    }

    // Glowing sun
    let sunRadius = s * 0.11
    let sunCenter = CGPoint(x: s * 0.64, y: s * 0.63)
    let sunRect = CGRect(
        x: sunCenter.x - sunRadius,
        y: sunCenter.y - sunRadius,
        width: sunRadius * 2,
        height: sunRadius * 2
    )
    cg.setFillColor(NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 0.30).cgColor)
    cg.fillEllipse(in: sunRect.insetBy(dx: -s * 0.04, dy: -s * 0.04))
    cg.setFillColor(NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.55, alpha: 0.95).cgColor)
    cg.fillEllipse(in: sunRect)

    // Back mountain peak
    let backMountain = NSBezierPath()
    backMountain.move(to: NSPoint(x: cardRect.minX, y: cardRect.minY))
    backMountain.line(to: NSPoint(x: cardRect.minX, y: s * 0.36))
    backMountain.line(to: NSPoint(x: s * 0.36, y: s * 0.62))
    backMountain.line(to: NSPoint(x: s * 0.62, y: s * 0.40))
    backMountain.line(to: NSPoint(x: s * 0.78, y: s * 0.53))
    backMountain.line(to: NSPoint(x: cardRect.maxX, y: s * 0.34))
    backMountain.line(to: NSPoint(x: cardRect.maxX, y: cardRect.minY))
    backMountain.close()
    NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.88, alpha: 0.55).setFill()
    backMountain.fill()

    // Front mountain peak
    let frontMountain = NSBezierPath()
    frontMountain.move(to: NSPoint(x: cardRect.minX, y: cardRect.minY))
    frontMountain.line(to: NSPoint(x: cardRect.minX, y: s * 0.24))
    frontMountain.line(to: NSPoint(x: s * 0.28, y: s * 0.48))
    frontMountain.line(to: NSPoint(x: s * 0.54, y: s * 0.26))
    frontMountain.line(to: NSPoint(x: s * 0.74, y: s * 0.42))
    frontMountain.line(to: NSPoint(x: cardRect.maxX, y: s * 0.22))
    frontMountain.line(to: NSPoint(x: cardRect.maxX, y: cardRect.minY))
    frontMountain.close()
    NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.20, alpha: 0.92).setFill()
    frontMountain.fill()

    // Subtle glass border
    path.lineWidth = max(1.5, s * 0.025)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outputIconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let iconsetURL = URL(fileURLWithPath: outputIconsetPath)
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    if let data = drawIcon(size: item.px) {
        let fileURL = iconsetURL.appendingPathComponent(item.name)
        try? data.write(to: fileURL)
    }
}
