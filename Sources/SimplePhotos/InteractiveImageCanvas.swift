import AppKit
import Combine
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

public struct InteractiveImageCanvas: NSViewRepresentable {
    @ObservedObject var viewModel: PhotoViewerViewModel
    var onUserActivity: () -> Void

    public init(viewModel: PhotoViewerViewModel, onUserActivity: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onUserActivity = onUserActivity
    }

    public func makeNSView(context: Context) -> InteractiveCanvasNSView {
        let view = InteractiveCanvasNSView()
        view.onUserActivity = onUserActivity
        view.bind(to: viewModel)
        return view
    }

    public func updateNSView(_ nsView: InteractiveCanvasNSView, context: Context) {
        nsView.onUserActivity = onUserActivity
        nsView.bind(to: viewModel)
        nsView.needsDisplay = true
    }
}

public final class InteractiveCanvasNSView: NSView {
    weak var viewModel: PhotoViewerViewModel?
    var onUserActivity: (() -> Void)?

    private var cancellable: AnyCancellable?
    private var lastDragLocation: NSPoint?
    private var mouseDownOrigin: NSPoint?
    private var isPanningImage = false
    private var trackingArea: NSTrackingArea?

    override public var acceptsFirstResponder: Bool { true }
    override public var isOpaque: Bool { false }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    public func bind(to vm: PhotoViewerViewModel) {
        if self.viewModel !== vm {
            self.viewModel = vm
            cancellable = vm.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
        }
        needsDisplay = true
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: - Direct Quartz Drawing

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let vm = viewModel,
              let cgImage = vm.currentCGImage,
              let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }

        let availW = bounds.width
        let availH = bounds.height
        guard availW > 8, availH > 8 else { return }

        // Seamless automatic background color fill directly in the same CGContext
        if vm.autoBackgroundColorEnabled && !vm.checkerboardBackground,
           let bgColor = vm.detectedBackgroundColor {
            ctx.saveGState()
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(bounds)
            ctx.restoreGState()
        }

        let rawW = max(1, CGFloat(cgImage.width))
        let rawH = max(1, CGFloat(cgImage.height))

        let rotSwap = (vm.rotationDegrees % 180) != 0
        let effectiveW = rotSwap ? rawH : rawW
        let effectiveH = rotSwap ? rawW : rawH

        let fitScale = min(availW / effectiveW, availH / effectiveH)
        if abs(vm.fitBaseScale - fitScale) > 0.001 {
            DispatchQueue.main.async { [weak vm] in
                vm?.fitBaseScale = fitScale
            }
        }

        let zoom = vm.zoomScale
        let drawW = rawW * fitScale * zoom
        let drawH = rawH * fitScale * zoom

        let centerX = availW * 0.5 + vm.panOffset.width
        let centerY = availH * 0.5 + vm.panOffset.height

        ctx.saveGState()
        ctx.interpolationQuality = zoom > 3.0 ? .none : .high

        ctx.translateBy(x: centerX, y: centerY)

        if vm.rotationDegrees != 0 {
            let radians = -CGFloat(vm.rotationDegrees) * .pi / 180.0
            ctx.rotate(by: radians)
        }

        if vm.isFlippedHorizontally {
            ctx.scaleBy(x: -1.0, y: 1.0)
        }

        let targetRect = CGRect(
            x: -drawW * 0.5,
            y: -drawH * 0.5,
            width: drawW,
            height: drawH
        )

        ctx.draw(cgImage, in: targetRect)
        ctx.restoreGState()
    }

    // MARK: - Clamping Pan Offset

    private func clampedPanOffset(_ proposed: CGSize, forZoom zoom: CGFloat) -> CGSize {
        guard let vm = viewModel, let cgImage = vm.currentCGImage, zoom > 1.0 else {
            return .zero
        }
        let availW = bounds.width
        let availH = bounds.height
        let rawW = max(1, CGFloat(cgImage.width))
        let rawH = max(1, CGFloat(cgImage.height))
        let rotSwap = (vm.rotationDegrees % 180) != 0
        let effectiveW = rotSwap ? rawH : rawW
        let effectiveH = rotSwap ? rawW : rawH
        let fitScale = min(availW / effectiveW, availH / effectiveH)

        let visualW = effectiveW * fitScale * zoom
        let visualH = effectiveH * fitScale * zoom

        let maxOffsetX = max(0, (visualW - availW) * 0.5 + 40)
        let maxOffsetY = max(0, (visualH - availH) * 0.5 + 40)

        return CGSize(
            width: max(-maxOffsetX, min(maxOffsetX, proposed.width)),
            height: max(-maxOffsetY, min(maxOffsetY, proposed.height))
        )
    }

    private func applyZoom(newScale: CGFloat, cursorPointInView: NSPoint) {
        guard let vm = viewModel, vm.hasImages else { return }
        let oldScale = vm.zoomScale
        let clampedScale = max(vm.minZoomScale, min(vm.maxZoomScale, newScale))
        guard abs(clampedScale - oldScale) > 0.0001 else { return }

        if clampedScale <= 1.0 {
            vm.setZoom(clampedScale, anchorOffset: .zero)
        } else {
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let pX = cursorPointInView.x - center.x
            let pY = cursorPointInView.y - center.y
            let ratio = clampedScale / oldScale
            let newOffsetX = pX - (pX - vm.panOffset.width) * ratio
            let newOffsetY = pY - (pY - vm.panOffset.height) * ratio
            let clampedOffset = clampedPanOffset(
                CGSize(width: newOffsetX, height: newOffsetY),
                forZoom: clampedScale
            )
            vm.setZoom(clampedScale, anchorOffset: clampedOffset)
        }
        needsDisplay = true
    }

    // MARK: - Side Click Navigation Zones

    public enum ClickZone {
        case leftPrevious
        case center
        case rightNext
    }

    /// Determines whether a click point in view/window coordinates falls in the invisible left/right navigation zones.
    public func navigationZone(for point: NSPoint, isFullScreen: Bool) -> ClickZone {
        return Self.navigationZone(for: point, in: bounds.size, isFullScreen: isFullScreen)
    }

    public static func navigationZone(for point: NSPoint, in size: NSSize, isFullScreen: Bool) -> ClickZone {
        let w = size.width
        let h = size.height
        guard w > 100, h > 60 else { return .center }

        if !isFullScreen {
            // Avoid top-left traffic lights area if window-level coordinates are passed
            if point.x < 92 && point.y > (h - 44) {
                return .center
            }
        }

        let sideWidth = max(90, min(320, w * 0.25))
        if point.x <= sideWidth {
            return .leftPrevious
        } else if point.x >= (w - sideWidth) {
            return .rightNext
        }
        return .center
    }

    // MARK: - Mouse & Trackpad Events

    override public func mouseMoved(with event: NSEvent) {
        onUserActivity?()
    }

    override public func mouseEntered(with event: NSEvent) {
        onUserActivity?()
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let vm = viewModel else { return }

        let pt = convert(event.locationInWindow, from: nil)
        let zone = navigationZone(for: pt, isFullScreen: vm.isFullScreen)

        // Invisible left/right side click navigation (works in both Windowed & Fullscreen, even on rapid clicks)
        if vm.canNavigate && vm.zoomScale <= 1.01 {
            switch zone {
            case .leftPrevious:
                vm.previousImage()
                return
            case .rightNext:
                vm.nextImage()
                return
            case .center:
                break
            }
        }

        // Double-click in center toggles Fullscreen
        if event.clickCount == 2 {
            vm.resetZoomToFit()
            vm.toggleFullScreen()
            return
        }

        onUserActivity?()

        if vm.zoomScale > 1.01 {
            isPanningImage = true
            lastDragLocation = pt
            mouseDownOrigin = pt
            NSCursor.closedHand.push()
        } else if !vm.isFullScreen {
            isPanningImage = false
            window?.performDrag(with: event)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        onUserActivity?()
        guard isPanningImage, let vm = viewModel, let last = lastDragLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - last.x
        let dy = current.y - last.y
        lastDragLocation = current

        let proposed = CGSize(
            width: vm.panOffset.width + dx,
            height: vm.panOffset.height + dy
        )
        vm.panOffset = clampedPanOffset(proposed, forZoom: vm.zoomScale)
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        if isPanningImage {
            isPanningImage = false
            lastDragLocation = nil
            NSCursor.pop()

            if let vm = viewModel, vm.canNavigate, let origin = mouseDownOrigin {
                let pt = convert(event.locationInWindow, from: nil)
                if hypot(pt.x - origin.x, pt.y - origin.y) < 5.0 {
                    switch navigationZone(for: pt, isFullScreen: vm.isFullScreen) {
                    case .leftPrevious:
                        vm.previousImage()
                    case .rightNext:
                        vm.nextImage()
                    case .center:
                        break
                    }
                }
            }
            mouseDownOrigin = nil
        }
    }

    override public func magnify(with event: NSEvent) {
        onUserActivity?()
        guard let vm = viewModel, vm.hasImages else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let factor = max(0.2, 1.0 + event.magnification)
        applyZoom(newScale: vm.zoomScale * factor, cursorPointInView: pt)
    }

    override public func smartMagnify(with event: NSEvent) {
        guard let vm = viewModel, vm.hasImages else { return }
        vm.resetZoomToFit()
        needsDisplay = true
    }

    override public func scrollWheel(with event: NSEvent) {
        onUserActivity?()
        guard let vm = viewModel, vm.hasImages else { return }

        let pt = convert(event.locationInWindow, from: nil)
        // Only zoom on scroll wheel if it's a physical mouse wheel (!hasPreciseScrollingDeltas)
        // or if Command / Option is held on a trackpad.
        let wantsWheelZoom = !event.hasPreciseScrollingDeltas
            || event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)

        if wantsWheelZoom {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return }
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
            let factor = pow(1.12, delta * sensitivity)
            applyZoom(newScale: vm.zoomScale * factor, cursorPointInView: pt)
        } else if vm.zoomScale > 1.01 {
            // Two-finger pan on trackpad while zoomed in
            let proposed = CGSize(
                width: vm.panOffset.width + event.scrollingDeltaX,
                height: vm.panOffset.height - event.scrollingDeltaY
            )
            vm.panOffset = clampedPanOffset(proposed, forZoom: vm.zoomScale)
            needsDisplay = true
        }
    }

    // MARK: - Context Menu

    override public func menu(for event: NSEvent) -> NSMenu? {
        guard let vm = viewModel else { return nil }
        let menu = NSMenu(title: "Simple Photos")

        let openItem = NSMenuItem(title: "Open Image or Folder…", action: #selector(ctxOpen), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        guard vm.hasImages else { return menu }

        menu.addItem(.separator())

        let fsItem = NSMenuItem(
            title: vm.isFullScreen ? "Exit Fullscreen" : "Enter Fullscreen",
            action: #selector(ctxFullScreen),
            keyEquivalent: "f"
        )
        fsItem.target = self
        menu.addItem(fsItem)

        let fitItem = NSMenuItem(title: "Fit to Window", action: #selector(ctxFit), keyEquivalent: "0")
        fitItem.target = self
        menu.addItem(fitItem)

        let actualItem = NSMenuItem(title: "Actual Size (1:1)", action: #selector(ctxActualSize), keyEquivalent: "1")
        actualItem.target = self
        menu.addItem(actualItem)

        menu.addItem(.separator())

        let rotLeft = NSMenuItem(title: "Rotate Left", action: #selector(ctxRotateLeft), keyEquivalent: "[")
        rotLeft.target = self
        menu.addItem(rotLeft)

        let rotRight = NSMenuItem(title: "Rotate Right", action: #selector(ctxRotateRight), keyEquivalent: "]")
        rotRight.target = self
        menu.addItem(rotRight)

        let flipItem = NSMenuItem(title: "Flip Horizontally", action: #selector(ctxFlip), keyEquivalent: "")
        flipItem.target = self
        menu.addItem(flipItem)

        let autoBgItem = NSMenuItem(
            title: "Automatic Background Color",
            action: #selector(ctxToggleAutoBackground),
            keyEquivalent: "b"
        )
        autoBgItem.state = vm.autoBackgroundColorEnabled ? .on : .off
        autoBgItem.target = self
        menu.addItem(autoBgItem)

        let checkerItem = NSMenuItem(
            title: vm.checkerboardBackground ? "Hide Transparency Grid" : "Show Transparency Grid",
            action: #selector(ctxToggleCheckerboard),
            keyEquivalent: "g"
        )
        checkerItem.target = self
        menu.addItem(checkerItem)

        menu.addItem(.separator())

        let yandexItem = NSMenuItem(
            title: "Search Image in Yandex",
            action: #selector(ctxSearchYandex),
            keyEquivalent: "y"
        )
        yandexItem.target = self
        menu.addItem(yandexItem)

        let copyImg = NSMenuItem(title: "Copy Image", action: #selector(ctxCopyImage), keyEquivalent: "c")
        copyImg.target = self
        menu.addItem(copyImg)

        let copyPath = NSMenuItem(title: "Copy File Path", action: #selector(ctxCopyPath), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(ctxReveal), keyEquivalent: "R")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let setDefItem = NSMenuItem(
            title: "Set as Default for All Images",
            action: #selector(ctxSetDefaultViewer),
            keyEquivalent: ""
        )
        setDefItem.state = vm.isDefaultImageViewer ? .on : .off
        setDefItem.target = self
        menu.addItem(setDefItem)

        let restorePrevItem = NSMenuItem(
            title: "Restore Preview as Default Viewer",
            action: #selector(ctxRestorePreviewViewer),
            keyEquivalent: ""
        )
        restorePrevItem.target = self
        menu.addItem(restorePrevItem)

        menu.addItem(.separator())

        let trash = NSMenuItem(title: "Move to Trash", action: #selector(ctxTrash), keyEquivalent: "\u{08}")
        trash.target = self
        menu.addItem(trash)

        return menu
    }

    @objc private func ctxOpen() { viewModel?.presentOpenPanel() }
    @objc private func ctxFullScreen() { viewModel?.toggleFullScreen() }
    @objc private func ctxFit() { viewModel?.resetZoomToFit() }
    @objc private func ctxActualSize() { viewModel?.toggleActualSizeOrFit() }
    @objc private func ctxRotateLeft() { viewModel?.rotateLeft() }
    @objc private func ctxRotateRight() { viewModel?.rotateRight() }
    @objc private func ctxFlip() { viewModel?.toggleFlipHorizontal() }
    @objc private func ctxToggleAutoBackground() { viewModel?.toggleAutoBackgroundColor() }
    @objc private func ctxToggleCheckerboard() { viewModel?.checkerboardBackground.toggle() }
    @objc private func ctxSearchYandex() { viewModel?.searchCurrentImageInYandex() }
    @objc private func ctxCopyImage() { viewModel?.copyImageToClipboard() }
    @objc private func ctxCopyPath() { viewModel?.copyFilePathToClipboard() }
    @objc private func ctxReveal() { viewModel?.revealInFinder() }
    @objc private func ctxSetDefaultViewer() { viewModel?.setAsDefaultForAllImages() }
    @objc private func ctxRestorePreviewViewer() { viewModel?.restorePreviewAsDefaultForAllImages() }
    @objc private func ctxTrash() { viewModel?.moveCurrentImageToTrash() }

    // MARK: - Drag and Drop

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }
        viewModel?.open(urls: urls)
        return true
    }
}
