import AppKit
import CoreGraphics
import Foundation

@MainActor
public enum SampleGalleryGenerator {
    public static func openDemoGallery(in viewModel: PhotoViewerViewModel) {
        let fm = FileManager.default
        let demoDir = fm.temporaryDirectory.appendingPathComponent("SimplePhotos-SampleGallery", isDirectory: true)
        try? fm.createDirectory(at: demoDir, withIntermediateDirectories: true)

        let specs: [(name: String, title: String, subtitle: String, colors: [NSColor], size: CGSize)] = [
            (
                "01_Alpine_Twilight.png",
                "Alpine Twilight",
                "Press → or ← to browse sibling photos in this folder",
                [
                    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.38, green: 0.18, blue: 0.45, alpha: 1),
                    NSColor(calibratedRed: 0.92, green: 0.45, blue: 0.34, alpha: 1)
                ],
                CGSize(width: 1920, height: 1200)
            ),
            (
                "02_Pacific_Emerald_Coast.png",
                "Pacific Emerald Coast",
                "Scroll wheel or pinch to zoom • Drag to pan",
                [
                    NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.32, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.58, alpha: 1),
                    NSColor(calibratedRed: 0.45, green: 0.86, blue: 0.76, alpha: 1)
                ],
                CGSize(width: 1920, height: 1200)
            ),
            (
                "03_Sahara_Golden_Dunes.png",
                "Sahara Golden Dunes",
                "Double-click to toggle 1:1 Actual Size & Fit to Window",
                [
                    NSColor(calibratedRed: 0.24, green: 0.11, blue: 0.06, alpha: 1),
                    NSColor(calibratedRed: 0.76, green: 0.38, blue: 0.14, alpha: 1),
                    NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.35, alpha: 1)
                ],
                CGSize(width: 1920, height: 1200)
            ),
            (
                "04_Nordic_Aurora_Portrait.png",
                "Nordic Aurora (Portrait)",
                "Press [ or ] to Rotate • Press I for Image Info",
                [
                    NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.18, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.48, alpha: 1),
                    NSColor(calibratedRed: 0.32, green: 0.92, blue: 0.62, alpha: 1)
                ],
                CGSize(width: 1200, height: 1600)
            ),
            (
                "05_Kyoto_Crimson_Autumn.png",
                "Kyoto Crimson Autumn",
                "Ultra-minimal borderless HUD fades out automatically when idle",
                [
                    NSColor(calibratedRed: 0.18, green: 0.05, blue: 0.12, alpha: 1),
                    NSColor(calibratedRed: 0.65, green: 0.12, blue: 0.24, alpha: 1),
                    NSColor(calibratedRed: 0.96, green: 0.56, blue: 0.32, alpha: 1)
                ],
                CGSize(width: 1920, height: 1200)
            )
        ]

        var firstFileURL: URL?
        for (idx, spec) in specs.enumerated() {
            let fileURL = demoDir.appendingPathComponent(spec.name)
            if firstFileURL == nil {
                firstFileURL = fileURL
            }
            if !fm.fileExists(atPath: fileURL.path) {
                renderSampleArtwork(
                    to: fileURL,
                    index: idx + 1,
                    total: specs.count,
                    title: spec.title,
                    subtitle: spec.subtitle,
                    colors: spec.colors,
                    size: spec.size
                )
            }
        }

        // Open JUST the first single image file to demonstrate Windows Photo Viewer's
        // automatic sibling discovery in the same folder!
        if let firstFileURL {
            viewModel.open(urls: [firstFileURL])
        }
    }

    private static func renderSampleArtwork(
        to url: URL,
        index: Int,
        total: Int,
        title: String,
        subtitle: String,
        colors: [NSColor],
        size: CGSize
    ) {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext

        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)

        // Multi-stop gradient sky
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: rect, angle: -65)
        }

        // Glowing sun / moon orb
        let sunCenter = CGPoint(x: size.width * (0.28 + CGFloat(index) * 0.11), y: size.height * 0.65)
        let sunRadius = min(size.width, size.height) * 0.16
        let sunRect = CGRect(
            x: sunCenter.x - sunRadius,
            y: sunCenter.y - sunRadius,
            width: sunRadius * 2,
            height: sunRadius * 2
        )
        cg.saveGState()
        cg.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        cg.fillEllipse(in: sunRect.insetBy(dx: -36, dy: -36))
        cg.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
        cg.fillEllipse(in: sunRect)
        cg.restoreGState()

        // Layered mountain silhouettes
        drawMountainLayer(
            in: cg,
            size: size,
            baseY: size.height * 0.42,
            amplitude: size.height * 0.14,
            seed: Double(index) * 1.7,
            color: NSColor.black.withAlphaComponent(0.28)
        )
        drawMountainLayer(
            in: cg,
            size: size,
            baseY: size.height * 0.28,
            amplitude: size.height * 0.11,
            seed: Double(index) * 3.1 + 1.2,
            color: NSColor.black.withAlphaComponent(0.52)
        )
        drawMountainLayer(
            in: cg,
            size: size,
            baseY: size.height * 0.16,
            amplitude: size.height * 0.07,
            seed: Double(index) * 4.9 + 2.5,
            color: NSColor.black.withAlphaComponent(0.78)
        )

        // Crisp typography badge
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            .paragraphStyle: paragraph
        ]
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 54, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82),
            .paragraphStyle: paragraph
        ]

        let badgeStr = "SAMPLE PHOTO 0\(index) / 0\(total)  •  \(width)×\(height)"
        (badgeStr as NSString).draw(at: NSPoint(x: 88, y: size.height - 130), withAttributes: badgeAttrs)
        (title as NSString).draw(at: NSPoint(x: 88, y: size.height - 205), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: NSPoint(x: 88, y: size.height - 255), withAttributes: subAttrs)

        NSGraphicsContext.restoreGraphicsState()

        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url, options: .atomic)
        }
    }

    private static func drawMountainLayer(
        in cg: CGContext,
        size: CGSize,
        baseY: CGFloat,
        amplitude: CGFloat,
        seed: Double,
        color: NSColor
    ) {
        cg.saveGState()
        cg.beginPath()
        cg.move(to: CGPoint(x: 0, y: 0))
        let steps = 64
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = CGFloat(t) * size.width
            let wave1 = sin(t * .pi * 2.5 + seed) * 0.6
            let wave2 = cos(t * .pi * 5.0 - seed * 1.3) * 0.3
            let wave3 = sin(t * .pi * 11.0 + seed * 0.7) * 0.1
            let y = baseY + CGFloat(wave1 + wave2 + wave3) * amplitude
            cg.addLine(to: CGPoint(x: x, y: y))
        }
        cg.addLine(to: CGPoint(x: size.width, y: 0))
        cg.closePath()
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }
}
