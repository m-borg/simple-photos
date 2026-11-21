import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageMetadata: Equatable, Sendable {
    public var filename: String = ""
    public var filePath: String = ""
    public var fileExtensionBadge: String = ""
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var fileSizeFormatted: String = ""
    public var formatName: String = ""
    public var colorModel: String = ""
    public var bitDepth: Int = 0
    public var cameraMakeModel: String = ""
    public var exposureInfo: String = ""
    public var dateString: String = ""
    public var isAnimated: Bool = false
    public var frameCount: Int = 1

    public var dimensionsString: String {
        guard pixelWidth > 0 && pixelHeight > 0 else { return "" }
        return "\(pixelWidth) × \(pixelHeight)"
    }
}

public struct AnimatedFrame: @unchecked Sendable {
    public let cgImage: CGImage
    public let duration: TimeInterval
}

private final class CachedPhotoEntry: @unchecked Sendable {
    let nsImage: NSImage
    let cgImage: CGImage
    let metadata: ImageMetadata
    let animatedFrames: [AnimatedFrame]
    let dominantBorderColor: NSColor?

    init(
        nsImage: NSImage,
        cgImage: CGImage,
        metadata: ImageMetadata,
        animatedFrames: [AnimatedFrame],
        dominantBorderColor: NSColor?
    ) {
        self.nsImage = nsImage
        self.cgImage = cgImage
        self.metadata = metadata
        self.animatedFrames = animatedFrames
        self.dominantBorderColor = dominantBorderColor
    }
}

@MainActor
public final class PhotoViewerViewModel: ObservableObject {
    /// Strictly still & animated image extensions (never video formats like mp4/mov/webm/mkv/avi).
    public nonisolated static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "heic", "heif",
        "bmp", "tiff", "tif", "ico", "icns", "svg", "avif", "jp2",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "pef", "raf",
        "tga", "exr", "hdr"
    ]

    public nonisolated static let excludedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts"
    ]

    // MARK: - Published State
    @Published public private(set) var imageURLs: [URL] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var currentImage: NSImage?
    @Published public private(set) var currentCGImage: CGImage?
    @Published public private(set) var metadata: ImageMetadata = ImageMetadata()
    @Published public private(set) var isLoading: Bool = false
    @Published public var statusToast: String?
    @Published public var isFullScreen: Bool = false
    @Published public private(set) var isDefaultImageViewer: Bool = false
    @Published public private(set) var isUpdatingDefaultViewer: Bool = false
    @Published public private(set) var isSearchingYandex: Bool = false
    @Published public private(set) var detectedBackgroundColor: NSColor?
    @Published public var autoBackgroundColorEnabled: Bool = {
        if let stored = UserDefaults.standard.object(forKey: "automaticBackgroundEnabled_v2") as? Bool {
            return stored
        }
        return false
    }() {
        didSet {
            UserDefaults.standard.set(autoBackgroundColorEnabled, forKey: "automaticBackgroundEnabled_v2")
        }
    }

    // Transform & Viewer Controls
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var fitBaseScale: CGFloat = 1.0
    @Published public var panOffset: CGSize = .zero
    @Published public var rotationDegrees: Int = 0
    @Published public var isFlippedHorizontally: Bool = false
    @Published public var showMetadataPopover: Bool = false
    @Published public var isSlideshowActive: Bool = false
    @Published public var isAlwaysOnTop: Bool = false {
        didSet {
            updateWindowLevel()
        }
    }

    // Selection & Crop State (Normalized 0...1 in displayed image coordinates, origin bottom-left)
    @Published public var normalizedSelectionRect: CGRect? = nil
    @Published public var isCropToolActive: Bool = false
    @Published public private(set) var canUndoEdit: Bool = false

    // Inline Filename Rename State
    @Published public var isRenamingFilename: Bool = false
    @Published public var renameDraftText: String = ""

    // Tracks per-URL session rotation and created crop files for undo
    private var sessionRotations: [URL: Int] = [:]
    private var createdCropURLsStack: [(createdURL: URL, originalURL: URL)] = []
    private let photoCache = NSCache<NSURL, CachedPhotoEntry>()
    private var slideshowTimer: Timer?
    private var animTimer: Timer?
    private var currentAnimatedFrames: [AnimatedFrame] = []
    private var currentAnimFrameIndex: Int = 0
    private var toastWorkItem: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?

    public var minZoomScale: CGFloat = 0.1
    public var maxZoomScale: CGFloat = 25.0

    public init() {
        photoCache.countLimit = 24
        isDefaultImageViewer = DefaultAppManager.isSimplePhotosCurrentlyDefault()
    }

    public func refreshDefaultViewerStatus() {
        isDefaultImageViewer = DefaultAppManager.isSimplePhotosCurrentlyDefault()
    }

    public func setAsDefaultForAllImages() {
        guard !isUpdatingDefaultViewer else { return }
        isUpdatingDefaultViewer = true
        Task {
            _ = await DefaultAppManager.setSimplePhotosAsDefault()
            self.isDefaultImageViewer = DefaultAppManager.isSimplePhotosCurrentlyDefault()
            self.isUpdatingDefaultViewer = false
            self.showToast("Simple Photos set as default for all images")
        }
    }

    public func restorePreviewAsDefaultForAllImages() {
        guard !isUpdatingDefaultViewer else { return }
        isUpdatingDefaultViewer = true
        Task {
            _ = await DefaultAppManager.restorePreviewAsDefault()
            self.isDefaultImageViewer = DefaultAppManager.isSimplePhotosCurrentlyDefault()
            self.isUpdatingDefaultViewer = false
            self.showToast("Restored macOS Preview as default image viewer")
        }
    }

    // MARK: - Computed Properties

    public var hasImages: Bool {
        !imageURLs.isEmpty
    }

    public var currentURL: URL? {
        guard currentIndex >= 0 && currentIndex < imageURLs.count else { return nil }
        return imageURLs[currentIndex]
    }

    public var canNavigate: Bool {
        imageURLs.count > 1
    }

    public var positionText: String {
        guard hasImages else { return "" }
        return "\(currentIndex + 1) / \(imageURLs.count)"
    }

    public var zoomPercentageText: String {
        if abs(zoomScale - 1.0) < 0.01 && panOffset == .zero {
            return "Fit"
        }
        let pct = Int(round(zoomScale * 100.0))
        return "\(pct)%"
    }

    /// Actual display percentage relative to 1:1 native image pixels (matching Windows 11 Photos bottom bar, e.g. "65%" or "259%")
    public var displayZoomPercentageText: String {
        let base = fitBaseScale > 0 ? fitBaseScale : 1.0
        let pct = max(1, Int(round(base * zoomScale * 100.0)))
        return "\(pct)%"
    }

    // MARK: - File & Folder Discovery (Windows Photo Viewer Behavior)

    public nonisolated static func isSupportedImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if excludedVideoExtensions.contains(ext) {
            return false
        }
        if supportedExtensions.contains(ext) {
            return true
        }
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .movie) || utType.conforms(to: .video) || utType.conforms(to: .audiovisualContent) {
                return false
            }
            return utType.conforms(to: .image)
        }
        return false
    }

    /// Scans a directory for all sibling image files, sorted using Finder's natural sort order.
    public nonisolated static func scanImagesInDirectory(_ directoryURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let filtered = contents.filter { url in
            guard isSupportedImageFile(url) else { return false }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                return true
            }
            return true
        }

        return filtered.sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    /// Opens one or more URLs. If a single image file is opened, automatically scans its parent folder
    /// so Left/Right arrows cycle through all sibling images just like Windows Photo Viewer.
    public func open(urls: [URL]) {
        guard let firstURL = urls.first else { return }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: firstURL.path, isDirectory: &isDir)
        guard exists else {
            showToast("File not found")
            return
        }

        if urls.count > 1 {
            var collected: [URL] = []
            for url in urls {
                var dirFlag: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &dirFlag) {
                    if dirFlag.boolValue {
                        collected.append(contentsOf: Self.scanImagesInDirectory(url))
                    } else if Self.isSupportedImageFile(url) {
                        collected.append(url.standardizedFileURL)
                    }
                }
            }
            if collected.count == 1, let single = collected.first {
                openSingleFileWithSiblings(single)
                return
            }
            if !collected.isEmpty {
                imageURLs = collected
                selectImage(at: 0, forceReload: true)
                return
            }
        }

        if isDir.boolValue {
            let folderImages = Self.scanImagesInDirectory(firstURL)
            guard !folderImages.isEmpty else {
                showToast("No supported images in “\(firstURL.lastPathComponent)”")
                return
            }
            imageURLs = folderImages
            selectImage(at: 0, forceReload: true)
        } else {
            openSingleFileWithSiblings(firstURL)
        }
    }

    private func openSingleFileWithSiblings(_ fileURL: URL) {
        let standardizedTarget = fileURL.standardizedFileURL
        guard Self.isSupportedImageFile(standardizedTarget) else {
            showToast("Unsupported file format (images & GIF/WebP only)")
            return
        }

        let parentDir = standardizedTarget.deletingLastPathComponent()
        let siblings = Self.scanImagesInDirectory(parentDir).map { $0.standardizedFileURL }

        if siblings.isEmpty {
            imageURLs = [standardizedTarget]
            selectImage(at: 0, forceReload: true)
            return
        }

        imageURLs = siblings
        if let idx = siblings.firstIndex(where: { $0.path == standardizedTarget.path }) {
            selectImage(at: idx, forceReload: true)
        } else if let idx = siblings.firstIndex(where: { $0.lastPathComponent == standardizedTarget.lastPathComponent }) {
            selectImage(at: idx, forceReload: true)
        } else {
            imageURLs.insert(standardizedTarget, at: 0)
            selectImage(at: 0, forceReload: true)
        }
    }

    // MARK: - Open Panel

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Image or Folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(urls: panel.urls)
        }
    }

    // MARK: - Navigation

    public func nextImage() {
        guard !imageURLs.isEmpty else { return }
        let nextIndex = (currentIndex + 1) % imageURLs.count
        selectImage(at: nextIndex)
    }

    public func previousImage() {
        guard !imageURLs.isEmpty else { return }
        let prevIndex = (currentIndex - 1 + imageURLs.count) % imageURLs.count
        selectImage(at: prevIndex)
    }

    public func firstImage() {
        guard !imageURLs.isEmpty else { return }
        selectImage(at: 0)
    }

    public func lastImage() {
        guard !imageURLs.isEmpty else { return }
        selectImage(at: imageURLs.count - 1)
    }

    public func selectImage(at index: Int, forceReload: Bool = false) {
        stopAnimatedTimer()
        guard !imageURLs.isEmpty else {
            currentImage = nil
            currentCGImage = nil
            metadata = ImageMetadata()
            return
        }

        let clampedIndex = max(0, min(index, imageURLs.count - 1))
        if clampedIndex == currentIndex && !forceReload && currentCGImage != nil {
            return
        }

        currentIndex = clampedIndex
        let url = imageURLs[clampedIndex]

        // Reset zoom, pan & selection on image change, restore any session rotation for this URL
        zoomScale = 1.0
        panOffset = .zero
        isFlippedHorizontally = false
        normalizedSelectionRect = nil
        isCropToolActive = false
        isRenamingFilename = false
        rotationDegrees = sessionRotations[url] ?? 0
        canUndoEdit = !createdCropURLsStack.isEmpty

        loadImage(for: url)
        preloadNeighbors(around: clampedIndex)
    }

    // MARK: - Image Decoding & Metadata Extraction

    private func loadImage(for url: URL) {
        loadTask?.cancel()

        if let cached = photoCache.object(forKey: url as NSURL) {
            applyLoadedEntry(cached)
            isLoading = false
            return
        }

        isLoading = true
        let targetURL = url

        loadTask = Task {
            let entry = await Task.detached(priority: .userInitiated) { () -> CachedPhotoEntry? in
                return Self.decodePhotoEntry(from: targetURL)
            }.value

            guard !Task.isCancelled, self.currentURL == targetURL else { return }

            if let entry {
                self.photoCache.setObject(entry, forKey: targetURL as NSURL)
                self.applyLoadedEntry(entry)
            } else {
                self.currentImage = nil
                self.currentCGImage = nil
                self.metadata = Self.extractMetadata(from: targetURL, fallbackCGImage: nil)
            }
            self.isLoading = false
        }
    }

    public func loadCurrentImageSynchronously() {
        guard let url = currentURL else { return }
        loadTask?.cancel()
        if let cached = photoCache.object(forKey: url as NSURL) {
            applyLoadedEntry(cached)
            isLoading = false
            return
        }
        if let entry = Self.decodePhotoEntry(from: url) {
            photoCache.setObject(entry, forKey: url as NSURL)
            applyLoadedEntry(entry)
        }
        isLoading = false
    }

    private func applyLoadedEntry(_ entry: CachedPhotoEntry) {
        self.currentImage = entry.nsImage
        self.currentCGImage = entry.cgImage
        self.metadata = entry.metadata
        self.detectedBackgroundColor = entry.dominantBorderColor
        self.currentAnimatedFrames = entry.animatedFrames
        self.currentAnimFrameIndex = 0
        if entry.animatedFrames.count > 1 {
            startAnimatedTimer()
        }
    }

    private func startAnimatedTimer() {
        stopAnimatedTimer()
        guard currentAnimatedFrames.count > 1 else { return }
        scheduleNextAnimFrame()
    }

    private func scheduleNextAnimFrame() {
        guard currentAnimatedFrames.count > 1 else { return }
        let duration = max(0.02, currentAnimatedFrames[currentAnimFrameIndex].duration)
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentAnimatedFrames.count > 1 else { return }
                self.currentAnimFrameIndex = (self.currentAnimFrameIndex + 1) % self.currentAnimatedFrames.count
                self.currentCGImage = self.currentAnimatedFrames[self.currentAnimFrameIndex].cgImage
                self.scheduleNextAnimFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stopAnimatedTimer() {
        animTimer?.invalidate()
        animTimer = nil
        currentAnimatedFrames = []
        currentAnimFrameIndex = 0
    }

    private func preloadNeighbors(around index: Int) {
        guard imageURLs.count > 1 else { return }
        let count = imageURLs.count
        let neighborIndices = [
            (index + 1) % count,
            (index - 1 + count) % count
        ]

        for idx in neighborIndices {
            let neighborURL = imageURLs[idx]
            if photoCache.object(forKey: neighborURL as NSURL) == nil {
                let cacheRef = photoCache
                Task.detached(priority: .utility) {
                    if let entry = Self.decodePhotoEntry(from: neighborURL) {
                        cacheRef.setObject(entry, forKey: neighborURL as NSURL)
                    }
                }
            }
        }
    }

    nonisolated private static func decodePhotoEntry(from url: URL) -> CachedPhotoEntry? {
        var decodedCG: CGImage?
        var animatedFrames: [AnimatedFrame] = []

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let count = CGImageSourceGetCount(source)

            if count > 1 {
                for i in 0..<count {
                    if let frameCG = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                        let duration = frameDuration(at: i, source: source)
                        animatedFrames.append(AnimatedFrame(cgImage: frameCG, duration: duration))
                    }
                }
                decodedCG = animatedFrames.first?.cgImage
            }

            if decodedCG == nil && count >= 1 {
                var maxDim = 4096
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
                    let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
                    if max(w, h) > 0 {
                        maxDim = max(w, h)
                    }
                }
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDim
                ]
                decodedCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
        }

        var nsImage: NSImage?
        if let cg = decodedCG {
            nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else if let loadedNS = NSImage(contentsOf: url) {
            nsImage = loadedNS
            var rect = NSRect(origin: .zero, size: loadedNS.size)
            if rect.width <= 0 || rect.height <= 0 {
                rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
            }
            decodedCG = loadedNS.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }

        guard let finalCG = decodedCG, let finalNS = nsImage else {
            return nil
        }

        let meta = extractMetadata(from: url, fallbackCGImage: finalCG)
        let dominantColor = extractDominantBorderColor(from: finalCG)
        return CachedPhotoEntry(
            nsImage: finalNS,
            cgImage: finalCG,
            metadata: meta,
            animatedFrames: animatedFrames,
            dominantBorderColor: dominantColor
        )
    }

    /// Samples the outer border pixels of the image (weighting corners and left/right edges)
    /// and finds the dominant background color mode so letterbox/pillarbox bars blend seamlessly.
    nonisolated public static func extractDominantBorderColor(from cgImage: CGImage) -> NSColor? {
        let sampleSize = 96
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixelBuffer = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixelBuffer,
                  width: sampleSize,
                  height: sampleSize,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }

        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        struct RGBSample {
            let r: Int
            let g: Int
            let b: Int
            let weight: Int
        }

        var samples: [RGBSample] = []
        samples.reserveCapacity(sampleSize * 8)

        var totalBorderCount = 0
        var opaqueBorderCount = 0

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let isLeftRight = (x <= 1 || x >= sampleSize - 2)
                let isTopBottom = (y <= 1 || y >= sampleSize - 2)
                guard isLeftRight || isTopBottom else { continue }

                totalBorderCount += 1
                let offset = (y * sampleSize + x) * bytesPerPixel
                let a = Int(pixelBuffer[offset + 3])
                guard a >= 235 else { continue }
                opaqueBorderCount += 1

                let r = Int(pixelBuffer[offset])
                let g = Int(pixelBuffer[offset + 1])
                let b = Int(pixelBuffer[offset + 2])

                let isCorner = (x <= 4 || x >= sampleSize - 5) && (y <= 4 || y >= sampleSize - 5)
                let weight: Int
                if isCorner {
                    weight = 5
                } else if isLeftRight {
                    weight = 2
                } else {
                    weight = 1
                }
                samples.append(RGBSample(r: r, g: g, b: b, weight: weight))
            }
        }

        // If the border is mostly transparent, don't force an opaque color
        guard totalBorderCount > 0,
              opaqueBorderCount * 5 >= totalBorderCount,
              !samples.isEmpty else {
            return nil
        }

        // 1. Coarse quantization into 32x32x32 buckets to find the dominant border cluster
        var bucketWeights: [Int: Int] = [:]
        for s in samples {
            let key = ((s.r >> 3) << 10) | ((s.g >> 3) << 5) | (s.b >> 3)
            bucketWeights[key, default: 0] += s.weight
        }

        guard let bestBucketKey = bucketWeights.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        let approxR = ((bestBucketKey >> 10) & 31) * 8 + 4
        let approxG = ((bestBucketKey >> 5) & 31) * 8 + 4
        let approxB = (bestBucketKey & 31) * 8 + 4

        // 2. Within the winning cluster (tolerance ±12 per channel), pick the exact most-frequent RGB triplet
        var exactCounts: [Int: Int] = [:]
        for s in samples {
            if abs(s.r - approxR) <= 12 && abs(s.g - approxG) <= 12 && abs(s.b - approxB) <= 12 {
                let exactKey = (s.r << 16) | (s.g << 8) | s.b
                exactCounts[exactKey, default: 0] += s.weight
            }
        }

        guard let winningExactKey = exactCounts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        let finalR = CGFloat((winningExactKey >> 16) & 0xFF) / 255.0
        let finalG = CGFloat((winningExactKey >> 8) & 0xFF) / 255.0
        let finalB = CGFloat(winningExactKey & 0xFF) / 255.0

        return NSColor(srgbRed: finalR, green: finalG, blue: finalB, alpha: 1.0)
    }

    /// Supports animated GIF, animated WebP, and APNG frame delays.
    nonisolated private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.08
        }
        if let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.01 {
                return unclamped
            }
            if let delay = gifDict[kCGImagePropertyGIFDelayTime] as? Double, delay > 0.01 {
                return delay
            }
        }
        if let webpDict = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let unclamped = webpDict[kCGImagePropertyWebPUnclampedDelayTime] as? Double, unclamped > 0.01 {
                return unclamped
            }
            if let delay = webpDict[kCGImagePropertyWebPDelayTime] as? Double, delay > 0.01 {
                return delay
            }
        }
        if let pngDict = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let unclamped = pngDict[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, unclamped > 0.01 {
                return unclamped
            }
            if let delay = pngDict[kCGImagePropertyAPNGDelayTime] as? Double, delay > 0.01 {
                return delay
            }
        }
        return 0.08
    }

    nonisolated private static func extractMetadata(from url: URL, fallbackCGImage: CGImage?) -> ImageMetadata {
        var meta = ImageMetadata()
        meta.filename = url.lastPathComponent
        meta.filePath = url.path
        let extUpper = url.pathExtension.uppercased()
        meta.fileExtensionBadge = extUpper == "JPEG" ? "JPG" : extUpper
        meta.formatName = extUpper

        if let cg = fallbackCGImage {
            meta.pixelWidth = cg.width
            meta.pixelHeight = cg.height
        }

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useKB, .useMB, .useGB]
                formatter.countStyle = .file
                meta.fileSizeFormatted = formatter.string(fromByteCount: size)
            }
            if let modDate = attrs[.modificationDate] as? Date {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                meta.dateString = df.string(from: modDate)
            }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return meta
        }

        let count = CGImageSourceGetCount(source)
        meta.frameCount = count
        meta.isAnimated = count > 1

        if let uti = CGImageSourceGetType(source) as String?,
           let utType = UTType(uti),
           let desc = utType.localizedDescription {
            meta.formatName = desc
        }

        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if meta.pixelWidth == 0, let w = props[kCGImagePropertyPixelWidth] as? Int {
                meta.pixelWidth = w
            }
            if meta.pixelHeight == 0, let h = props[kCGImagePropertyPixelHeight] as? Int {
                meta.pixelHeight = h
            }
            if let colorModel = props[kCGImagePropertyColorModel] as? String {
                meta.colorModel = colorModel
            }
            if let depth = props[kCGImagePropertyDepth] as? Int {
                meta.bitDepth = depth
            }

            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !make.isEmpty || !model.isEmpty {
                    if model.lowercased().hasPrefix(make.lowercased()) {
                        meta.cameraMakeModel = model
                    } else {
                        meta.cameraMakeModel = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
                    }
                }
            }

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var parts: [String] = []
                if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                    parts.append("\(Int(round(focal)))mm")
                }
                if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                    parts.append(String(format: "f/%.1f", fNumber))
                }
                if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                    if exposure < 1.0 {
                        let denom = Int(round(1.0 / exposure))
                        parts.append("1/\(denom)s")
                    } else {
                        parts.append(String(format: "%.1fs", exposure))
                    }
                }
                if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
                    parts.append("ISO \(iso)")
                }
                meta.exposureInfo = parts.joined(separator: " · ")

                if let dateOrig = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    meta.dateString = dateOrig
                }
            }
        }

        return meta
    }

    // MARK: - Zoom, Pan & Rotation Controls

    public func zoomIn(step: CGFloat = 1.25) {
        setZoom(zoomScale * step)
    }

    public func zoomOut(step: CGFloat = 1.25) {
        setZoom(zoomScale / step)
    }

    public func setZoom(_ newScale: CGFloat, anchorOffset: CGSize? = nil) {
        let clamped = max(minZoomScale, min(maxZoomScale, newScale))
        if let anchorOffset {
            panOffset = anchorOffset
        } else if clamped <= 1.0 {
            panOffset = .zero
        }
        zoomScale = clamped
    }

    public static let zoomPercentagePresets: [Int] = [10, 25, 50, 75, 100, 150, 200, 300, 400, 500]

    public func setDisplayZoomPercentage(_ percentage: Int) {
        let base = fitBaseScale > 0 ? fitBaseScale : 1.0
        let targetScale = (CGFloat(percentage) / 100.0) / base
        setZoom(targetScale)
    }

    public func resetZoomToFit() {
        zoomScale = 1.0
        panOffset = .zero
    }

    public func toggleActualSizeOrFit() {
        let base = fitBaseScale > 0 ? fitBaseScale : 1.0
        let oneToOneScale = 1.0 / base
        if abs(zoomScale - oneToOneScale) > 0.02 {
            setZoom(oneToOneScale)
        } else {
            resetZoomToFit()
        }
    }

    public func rotateLeft() {
        rotationDegrees = (rotationDegrees - 90 + 360) % 360
        if let url = currentURL {
            sessionRotations[url] = rotationDegrees
        }
    }

    public func rotateRight() {
        rotationDegrees = (rotationDegrees + 90) % 360
        if let url = currentURL {
            sessionRotations[url] = rotationDegrees
        }
    }

    public func toggleFlipHorizontal() {
        isFlippedHorizontally.toggle()
    }

    public func toggleAutoBackgroundColor() {
        autoBackgroundColorEnabled.toggle()
        showToast(autoBackgroundColorEnabled ? "Automatic Background: On" : "Automatic Background: Off")
    }

    // MARK: - File Actions (Trash, Finder, Copy)

    public func moveCurrentImageToTrash() {
        guard let url = currentURL else { return }
        let filename = url.lastPathComponent

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            photoCache.removeObject(forKey: url as NSURL)
            sessionRotations.removeValue(forKey: url)
            imageURLs.remove(at: currentIndex)

            if !isFullScreen {
                showToast("Moved “\(filename)” to Trash")
            }

            if imageURLs.isEmpty {
                stopAnimatedTimer()
                currentIndex = 0
                currentImage = nil
                currentCGImage = nil
                metadata = ImageMetadata()
            } else {
                let nextIdx = min(currentIndex, imageURLs.count - 1)
                selectImage(at: nextIdx, forceReload: true)
            }
        } catch {
            if !isFullScreen {
                showToast("Could not move “\(filename)” to Trash")
            }
        }
    }

    public func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Inline Filename Renaming

    public var currentFileExtensionWithDot: String {
        guard let url = currentURL else { return "" }
        let ext = url.pathExtension
        return ext.isEmpty ? "" : ".\(ext)"
    }

    public func beginRenamingCurrentImage() {
        guard let url = currentURL else { return }
        renameDraftText = url.deletingPathExtension().lastPathComponent
        isRenamingFilename = true
    }

    public func cancelRenamingCurrentImage() {
        isRenamingFilename = false
    }

    @discardableResult
    public func commitRenameCurrentImage(to rawInput: String? = nil) -> Bool {
        let draft = (rawInput ?? renameDraftText).trimmingCharacters(in: .whitespacesAndNewlines)
        isRenamingFilename = false

        guard let oldURL = currentURL, !draft.isEmpty else {
            return false
        }

        var sanitized = draft
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let origExt = oldURL.pathExtension
        if !origExt.isEmpty && sanitized.lowercased().hasSuffix(".\(origExt.lowercased())") {
            sanitized = String(sanitized.dropLast(origExt.count + 1))
        }
        guard !sanitized.isEmpty else { return false }

        let newFilename = origExt.isEmpty ? sanitized : "\(sanitized).\(origExt)"
        if newFilename == oldURL.lastPathComponent {
            return true
        }

        let parentDir = oldURL.deletingLastPathComponent()
        let newURL = parentDir.appendingPathComponent(newFilename).standardizedFileURL
        let fm = FileManager.default

        if fm.fileExists(atPath: newURL.path) && newURL.path.lowercased() != oldURL.path.lowercased() {
            showToast("“\(newFilename)” already exists")
            return false
        }

        do {
            try fm.moveItem(at: oldURL, to: newURL)

            if let cached = photoCache.object(forKey: oldURL as NSURL) {
                photoCache.removeObject(forKey: oldURL as NSURL)
                photoCache.setObject(cached, forKey: newURL as NSURL)
            }
            if let rot = sessionRotations.removeValue(forKey: oldURL) {
                sessionRotations[newURL] = rot
            }

            imageURLs[currentIndex] = newURL
            metadata.filename = newURL.lastPathComponent
            metadata.filePath = newURL.path

            NSWorkspace.shared.noteFileSystemChanged(parentDir.path)
            showToast("Renamed to “\(newURL.lastPathComponent)”")
            return true
        } catch {
            showToast("Could not rename file")
            return false
        }
    }

    public func copyImageToClipboard() {
        if let cgImage = currentCGImage, normalizedSelectionRect != nil {
            let oriented = Self.createOrientedCGImage(
                from: cgImage,
                rotationDegrees: rotationDegrees,
                isFlippedHorizontally: isFlippedHorizontally
            )
            if let pixelRect = selectedPixelRect(for: oriented),
               let croppedCG = Self.renderStandaloneCroppedCGImage(from: oriented, pixelRect: pixelRect) {
                let nsImg = NSImage(cgImage: croppedCG, size: NSSize(width: croppedCG.width, height: croppedCG.height))
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([nsImg])
                clearSelection()
                showToast("Copied selection")
                return
            }
        }

        guard let image = currentImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        if !isFullScreen {
            showToast("Copied image")
        }
    }

    // MARK: - Selection, Crop, Cut & Undo (Preview-style)

    public var hasActiveSelection: Bool {
        guard let rect = normalizedSelectionRect else { return false }
        return rect.width > 0.005 && rect.height > 0.005
    }

    public var selectedPixelDimensionsText: String {
        guard let cgImage = currentCGImage, hasActiveSelection else { return "" }
        let rotSwap = (rotationDegrees % 180) != 0
        let w = CGFloat(rotSwap ? cgImage.height : cgImage.width)
        let h = CGFloat(rotSwap ? cgImage.width : cgImage.height)
        guard let norm = normalizedSelectionRect else { return "" }
        let pw = max(1, Int(round(norm.width * w)))
        let ph = max(1, Int(round(norm.height * h)))
        return "\(pw) × \(ph)"
    }

    public func toggleCropMode() {
        guard hasImages else { return }
        if hasActiveSelection || isCropToolActive {
            clearSelection()
        } else {
            isCropToolActive = true
            normalizedSelectionRect = CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76)
        }
    }

    public func clearSelection() {
        normalizedSelectionRect = nil
        isCropToolActive = false
    }

    public func selectedPixelRect(for cgImage: CGImage) -> CGRect? {
        guard let norm = normalizedSelectionRect, norm.width > 0.005, norm.height > 0.005 else {
            return nil
        }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let minX = max(0.0, min(1.0, norm.minX))
        let maxX = max(0.0, min(1.0, norm.maxX))
        let minY = max(0.0, min(1.0, norm.minY))
        let maxY = max(0.0, min(1.0, norm.maxY))

        let px = floor(minX * w)
        let py = floor((1.0 - maxY) * h)
        let pw = max(1.0, round((maxX - minX) * w))
        let ph = max(1.0, round((maxY - minY) * h))

        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let rect = CGRect(x: px, y: py, width: pw, height: ph).intersection(bounds)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// Renders the cropped rectangle into a brand-new standalone CGContext buffer so no reference
    /// to the original uncropped parent buffer or embedded metadata remains.
    nonisolated public static func renderStandaloneCroppedCGImage(
        from oriented: CGImage,
        pixelRect: CGRect
    ) -> CGImage? {
        guard let subImage = oriented.cropping(to: pixelRect) else {
            return nil
        }
        let w = subImage.width
        let h = subImage.height
        guard w >= 1, h >= 1,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: w * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return subImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(subImage, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? subImage
    }

    /// Always saves the cropped selection as a new image file alongside the untouched original.
    public func cropToSelection() {
        guard let originalURL = currentURL,
              let cgImage = currentCGImage,
              hasActiveSelection else {
            return
        }

        let oriented = Self.createOrientedCGImage(
            from: cgImage,
            rotationDegrees: rotationDegrees,
            isFlippedHorizontally: isFlippedHorizontally
        )
        guard let pixelRect = selectedPixelRect(for: oriented),
              let croppedCG = Self.renderStandaloneCroppedCGImage(from: oriented, pixelRect: pixelRect) else {
            showToast("Selection too small to crop")
            return
        }

        guard let newURL = saveAsNewImageFile(croppedCG, basedOn: originalURL, suffix: "cropped") else {
            showToast("Could not save cropped image")
            return
        }

        createdCropURLsStack.append((createdURL: newURL, originalURL: originalURL))
        canUndoEdit = true
        normalizedSelectionRect = nil
        isCropToolActive = false

        // Refresh sibling list in folder and switch to the newly created cropped image
        let parentDir = newURL.deletingLastPathComponent()
        let updatedSiblings = Self.scanImagesInDirectory(parentDir).map { $0.standardizedFileURL }
        if !updatedSiblings.isEmpty {
            imageURLs = updatedSiblings
        } else {
            imageURLs.insert(newURL, at: min(currentIndex + 1, imageURLs.count))
        }

        if let newIdx = imageURLs.firstIndex(where: { $0.path == newURL.path }) {
            selectImage(at: newIdx, forceReload: true)
        } else {
            loadCurrentImageSynchronously()
        }

        showToast("Saved “\(newURL.lastPathComponent)”")
    }

    public func undoLastEdit() {
        guard let lastEntry = createdCropURLsStack.popLast() else {
            return
        }
        canUndoEdit = !createdCropURLsStack.isEmpty

        let createdURL = lastEntry.createdURL
        let originalURL = lastEntry.originalURL

        try? FileManager.default.trashItem(at: createdURL, resultingItemURL: nil)
        photoCache.removeObject(forKey: createdURL as NSURL)

        let parentDir = originalURL.deletingLastPathComponent()
        let updatedSiblings = Self.scanImagesInDirectory(parentDir).map { $0.standardizedFileURL }
        if !updatedSiblings.isEmpty {
            imageURLs = updatedSiblings
        } else {
            imageURLs.removeAll { $0.path == createdURL.path }
        }

        if let origIdx = imageURLs.firstIndex(where: { $0.path == originalURL.path }) {
            selectImage(at: origIdx, forceReload: true)
        } else if !imageURLs.isEmpty {
            selectImage(at: min(currentIndex, imageURLs.count - 1), forceReload: true)
        }

        showToast("Undid crop (removed “\(createdURL.lastPathComponent)”)")
    }

    /// Writes `newCGImage` to a brand-new unique file alongside `originalURL`, leaving `originalURL` untouched.
    private func saveAsNewImageFile(_ newCGImage: CGImage, basedOn originalURL: URL, suffix: String) -> URL? {
        let origExt = originalURL.pathExtension.lowercased()
        let targetExt: String
        let utTypeIdentifier: CFString

        switch origExt {
        case "jpg", "jpeg", "jpe":
            targetExt = origExt
            utTypeIdentifier = UTType.jpeg.identifier as CFString
        case "png":
            targetExt = "png"
            utTypeIdentifier = UTType.png.identifier as CFString
        case "heic", "heif":
            targetExt = origExt
            utTypeIdentifier = UTType.heic.identifier as CFString
        case "tiff", "tif":
            targetExt = origExt
            utTypeIdentifier = UTType.tiff.identifier as CFString
        case "bmp":
            targetExt = "bmp"
            utTypeIdentifier = UTType.bmp.identifier as CFString
        default:
            // Formats like WebP that macOS CGImageDestination doesn't write natively are saved cleanly as .png
            targetExt = "png"
            utTypeIdentifier = UTType.png.identifier as CFString
        }

        let parentDir = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        var candidateURL = parentDir.appendingPathComponent("\(baseName)_\(suffix).\(targetExt)")
        var counter = 2
        while fm.fileExists(atPath: candidateURL.path) {
            candidateURL = parentDir.appendingPathComponent("\(baseName)_\(suffix)_\(counter).\(targetExt)")
            counter += 1
        }

        guard let dest = CGImageDestinationCreateWithURL(candidateURL as CFURL, utTypeIdentifier, 1, nil) else {
            return nil
        }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(dest, newCGImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }

        // Notify Finder that the directory contents changed so it generates a fresh thumbnail immediately
        NSWorkspace.shared.noteFileSystemChanged(parentDir.path)
        return candidateURL.standardizedFileURL
    }

    nonisolated public static func createOrientedCGImage(
        from cgImage: CGImage,
        rotationDegrees: Int,
        isFlippedHorizontally: Bool
    ) -> CGImage {
        let normRot = ((rotationDegrees % 360) + 360) % 360
        if normRot == 0 && !isFlippedHorizontally {
            return cgImage
        }

        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        let rotSwap = (normRot % 180) != 0
        let targetW = Int(rotSwap ? origH : origW)
        let targetH = Int(rotSwap ? origW : origH)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: targetW,
                  height: targetH,
                  bitsPerComponent: 8,
                  bytesPerRow: targetW * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return cgImage
        }

        ctx.translateBy(x: CGFloat(targetW) * 0.5, y: CGFloat(targetH) * 0.5)
        if normRot != 0 {
            let radians = -CGFloat(normRot) * .pi / 180.0
            ctx.rotate(by: radians)
        }
        if isFlippedHorizontally {
            ctx.scaleBy(x: -1.0, y: 1.0)
        }
        ctx.draw(cgImage, in: CGRect(x: -origW * 0.5, y: -origH * 0.5, width: origW, height: origH))
        return ctx.makeImage() ?? cgImage
    }

    public func copyFilePathToClipboard() {
        guard let url = currentURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        if !isFullScreen {
            showToast("Copied file path")
        }
    }

    public func searchCurrentImageInYandex() {
        guard let cgImage = currentCGImage, !isSearchingYandex else { return }
        isSearchingYandex = true
        showToast("Searching image in Yandex…")

        Task {
            do {
                let searchURL = try await YandexImageSearch.searchImage(cgImage: cgImage)
                self.isSearchingYandex = false
                NSWorkspace.shared.open(searchURL)
            } catch {
                self.isSearchingYandex = false
                self.showToast("Yandex search failed")
            }
        }
    }

    // MARK: - Slideshow

    public func toggleSlideshow() {
        guard hasImages else { return }
        isSlideshowActive.toggle()
        if isSlideshowActive {
            slideshowTimer?.invalidate()
            slideshowTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.nextImage()
                }
            }
        } else {
            stopSlideshow()
        }
    }

    public func stopSlideshow() {
        isSlideshowActive = false
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    // MARK: - Window Helpers

    private func updateWindowLevel() {
        for window in NSApplication.shared.windows {
            window.level = isAlwaysOnTop ? .floating : .normal
        }
    }

    public func toggleFullScreen() {
        showMetadataPopover = false
        statusToast = nil
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            window.toggleFullScreen(nil)
        }
    }

    public func showToast(_ message: String, duration: TimeInterval = 1.4) {
        guard !isFullScreen else { return }
        toastWorkItem?.cancel()
        statusToast = message
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.statusToast = nil
            }
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}
