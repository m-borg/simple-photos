import AppKit
import XCTest
@testable import SimplePhotos

@MainActor
final class PhotoViewerViewModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        tempDir = fm.temporaryDirectory.appendingPathComponent("SimplePhotosTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func createTestPNG(
        named name: String,
        width: Int = 320,
        height: Int = 200,
        fillColor: NSColor = NSColor(deviceRed: 0.95, green: 0.2, blue: 0.15, alpha: 1.0)
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let rep = NSBitmapImageRep(
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
        )!
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            fillColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
        return url
    }

    func testOpeningSingleImageAutoDiscoversAndNaturallySortsSiblings() throws {
        _ = try createTestPNG(named: "Photo_10.png")
        let target2 = try createTestPNG(named: "Photo_2.png")
        _ = try createTestPNG(named: "Photo_1.png")
        try "notes".write(to: tempDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let vm = PhotoViewerViewModel()
        vm.open(urls: [target2])

        XCTAssertEqual(vm.imageURLs.count, 3)
        XCTAssertEqual(vm.imageURLs.map(\.lastPathComponent), ["Photo_1.png", "Photo_2.png", "Photo_10.png"])
        XCTAssertEqual(vm.currentIndex, 1, "Should start at Photo_2.png which was opened")
        XCTAssertEqual(vm.positionText, "2 / 3")
    }

    func testLeftRightNavigationWrapsAroundFolder() throws {
        let img1 = try createTestPNG(named: "A.png")
        _ = try createTestPNG(named: "B.png")
        _ = try createTestPNG(named: "C.png")

        let vm = PhotoViewerViewModel()
        vm.open(urls: [img1])
        XCTAssertEqual(vm.currentIndex, 0)

        vm.previousImage()
        XCTAssertEqual(vm.currentIndex, 2)
        XCTAssertEqual(vm.currentURL?.lastPathComponent, "C.png")

        vm.nextImage()
        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertEqual(vm.currentURL?.lastPathComponent, "A.png")

        vm.nextImage()
        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertEqual(vm.currentURL?.lastPathComponent, "B.png")
    }

    func testRotationPersistsInSessionAcrossNavigation() throws {
        let img1 = try createTestPNG(named: "first.png")
        _ = try createTestPNG(named: "second.png")

        let vm = PhotoViewerViewModel()
        vm.open(urls: [img1])

        XCTAssertEqual(vm.rotationDegrees, 0)
        vm.rotateRight()
        XCTAssertEqual(vm.rotationDegrees, 90)

        vm.nextImage()
        XCTAssertEqual(vm.rotationDegrees, 0)

        vm.previousImage()
        XCTAssertEqual(vm.rotationDegrees, 90)

        vm.rotateLeft()
        XCTAssertEqual(vm.rotationDegrees, 0)
    }

    func testZoomAndActualSizeToggle() throws {
        let img = try createTestPNG(named: "zoom.png", width: 2000, height: 1000)
        let vm = PhotoViewerViewModel()
        vm.open(urls: [img])
        vm.fitBaseScale = 0.5

        XCTAssertEqual(vm.zoomScale, 1.0)
        XCTAssertEqual(vm.zoomPercentageText, "Fit")

        vm.toggleActualSizeOrFit()
        XCTAssertEqual(vm.zoomScale, 2.0, accuracy: 0.01)
        XCTAssertEqual(vm.zoomPercentageText, "200%")

        vm.toggleActualSizeOrFit()
        XCTAssertEqual(vm.zoomScale, 1.0, accuracy: 0.01)
        XCTAssertEqual(vm.zoomPercentageText, "Fit")
    }

    func testInteractiveCanvasActuallyRendersNonBlackImagePixels() throws {
        let vividRed = NSColor(deviceRed: 0.92, green: 0.14, blue: 0.12, alpha: 1.0)
        let imgURL = try createTestPNG(named: "vivid_red.png", width: 400, height: 300, fillColor: vividRed)

        let vm = PhotoViewerViewModel()
        vm.open(urls: [imgURL])
        vm.loadCurrentImageSynchronously()

        XCTAssertNotNil(vm.currentCGImage, "currentCGImage must be decoded")

        let canvas = InteractiveCanvasNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        canvas.bind(to: vm)

        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("Failed to allocate bitmapImageRepForCachingDisplay")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)

        // Sample pixel at the center of the canvas (300, 200)
        guard let centerColor = bitmap.colorAt(x: 300, y: 200)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Could not read center pixel color")
            return
        }

        XCTAssertGreaterThan(centerColor.redComponent, 0.8, "Center pixel should be vivid red, not black!")
        XCTAssertLessThan(centerColor.greenComponent, 0.3)
        XCTAssertLessThan(centerColor.blueComponent, 0.3)
    }

    func testSingleWindowGuaranteeWhenOpeningFiles() throws {
        let img1 = try createTestPNG(named: "one.png")
        let img2 = try createTestPNG(named: "two.png")

        let delegate = AppDelegate()
        let w1 = delegate.ensureMainWindow()
        delegate.application(NSApplication.shared, open: [img1])
        let w2 = delegate.ensureMainWindow()
        delegate.application(NSApplication.shared, open: [img2])

        XCTAssertTrue(w1 === w2, "AppDelegate must always reuse the single mainWindow")
    }

    func testVideoFilesAreStrictlyExcludedFromFolderScan() throws {
        let img1 = try createTestPNG(named: "photo.png")
        let gif1 = try createTestPNG(named: "anim.gif")
        let webp1 = try createTestPNG(named: "anim.webp")
        try "fake-video".write(to: tempDir.appendingPathComponent("clip.mp4"), atomically: true, encoding: .utf8)
        try "fake-video".write(to: tempDir.appendingPathComponent("movie.mov"), atomically: true, encoding: .utf8)
        try "fake-video".write(to: tempDir.appendingPathComponent("video.webm"), atomically: true, encoding: .utf8)

        XCTAssertTrue(PhotoViewerViewModel.isSupportedImageFile(img1))
        XCTAssertTrue(PhotoViewerViewModel.isSupportedImageFile(gif1))
        XCTAssertTrue(PhotoViewerViewModel.isSupportedImageFile(webp1))
        XCTAssertFalse(PhotoViewerViewModel.isSupportedImageFile(tempDir.appendingPathComponent("clip.mp4")))
        XCTAssertFalse(PhotoViewerViewModel.isSupportedImageFile(tempDir.appendingPathComponent("movie.mov")))
        XCTAssertFalse(PhotoViewerViewModel.isSupportedImageFile(tempDir.appendingPathComponent("video.webm")))

        let vm = PhotoViewerViewModel()
        vm.open(urls: [img1])
        XCTAssertEqual(vm.imageURLs.map(\.lastPathComponent), ["anim.gif", "anim.webp", "photo.png"])
    }

    func testInvisibleLeftRightSideClickZones() throws {
        let canvas = InteractiveCanvasNSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))

        // Extreme left edge (0px and negative out-of-screen boundary) -> Previous
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 0, y: 350), isFullScreen: false), .leftPrevious)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: -1, y: 350), isFullScreen: true), .leftPrevious)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 80, y: 350), isFullScreen: false), .leftPrevious)

        // Extreme right edge (width and width+1 out-of-screen boundary) -> Next
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 1000, y: 350), isFullScreen: false), .rightNext)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 1001, y: 350), isFullScreen: true), .rightNext)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 920, y: 350), isFullScreen: false), .rightNext)

        // Center click -> Center (drag / double-click fullscreen)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 500, y: 350), isFullScreen: false), .center)
        // Top-left traffic light area in windowed mode -> Center (safe from accidental previous)
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 40, y: 680), isFullScreen: false), .center)
        // Top-left in fullscreen mode (no traffic lights) -> Left Previous
        XCTAssertEqual(canvas.navigationZone(for: NSPoint(x: 40, y: 680), isFullScreen: true), .leftPrevious)
    }

    func testAutomaticBackgroundColorMatchesImageEdgesSeamlessly() throws {
        // 1. Sage green square image (300x300) displayed in a wider 800x400 canvas
        let sageGreen = NSColor(srgbRed: 206.0 / 255.0, green: 211.0 / 255.0, blue: 200.0 / 255.0, alpha: 1.0)
        let imgURL = try createTestPNG(named: "sage_art.png", width: 300, height: 300, fillColor: sageGreen)

        let vm = PhotoViewerViewModel()
        vm.autoBackgroundColorEnabled = true
        vm.open(urls: [imgURL])
        vm.loadCurrentImageSynchronously()

        guard let detected = vm.detectedBackgroundColor?.usingColorSpace(.sRGB) else {
            XCTFail("Expected detectedBackgroundColor to be non-nil")
            return
        }
        XCTAssertEqual(detected.redComponent, 206.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(detected.greenComponent, 211.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(detected.blueComponent, 200.0 / 255.0, accuracy: 0.02)

        // Render wide 800x400 canvas and check the left pillarbox bar at x = 40, y = 200
        let canvas = InteractiveCanvasNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        canvas.bind(to: vm)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("Could not create bitmap")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)

        guard let pillarboxColor = bitmap.colorAt(x: 40, y: 200)?.usingColorSpace(.sRGB) else {
            XCTFail("Could not sample pillarbox pixel")
            return
        }
        XCTAssertEqual(pillarboxColor.redComponent, 206.0 / 255.0, accuracy: 0.03)
        XCTAssertEqual(pillarboxColor.greenComponent, 211.0 / 255.0, accuracy: 0.03)
        XCTAssertEqual(pillarboxColor.blueComponent, 200.0 / 255.0, accuracy: 0.03)
    }

    func testDefaultAppManagerSupportedUTTypesExcludesVideos() throws {
        let types = DefaultAppManager.allSupportedImageUTTypes()
        let identifiers = Set(types.map(\.identifier))

        XCTAssertTrue(identifiers.contains("public.jpeg"))
        XCTAssertTrue(identifiers.contains("public.png"))
        XCTAssertTrue(identifiers.contains("com.compuserve.gif"))
        XCTAssertTrue(identifiers.contains("org.webmproject.webp"))
        XCTAssertFalse(identifiers.contains("public.mpeg-4"))
        XCTAssertFalse(identifiers.contains("com.apple.quicktime-movie"))
    }

    func testYandexImageSearchPreparationAndURLFormatting() throws {
        let imgURL = try createTestPNG(named: "large_art.png", width: 2000, height: 1000)
        let vm = PhotoViewerViewModel()
        vm.open(urls: [imgURL])
        vm.loadCurrentImageSynchronously()

        guard let cgImage = vm.currentCGImage else {
            XCTFail("Expected currentCGImage")
            return
        }

        guard let jpegData = YandexImageSearch.prepareJPEGData(from: cgImage, maxDimension: 512) else {
            XCTFail("Expected JPEG data to be encoded")
            return
        }
        XCTAssertGreaterThan(jpegData.count, 100)

        // Verify downscaled dimensions (2000x1000 -> 512x256)
        guard let decodedRep = NSBitmapImageRep(data: jpegData) else {
            XCTFail("Expected valid JPEG NSBitmapImageRep")
            return
        }
        XCTAssertEqual(decodedRep.pixelsWide, 512)
        XCTAssertEqual(decodedRep.pixelsHigh, 256)

        let searchURL = YandexImageSearch.buildSearchURL(
            uploadedImageURL: "https://avatars.mds.yandex.net/get-images-cbir/12345/orig",
            zone: "com"
        )
        XCTAssertEqual(
            searchURL?.absoluteString,
            "https://yandex.com/images/search?rpt=imageview&url=https%3A%2F%2Favatars.mds.yandex.net%2Fget-images-cbir%2F12345%2Forig"
        )
    }
}
