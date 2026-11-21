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
    public enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    public enum InlineSelectionButton: Equatable {
        case crop
        case copy
        case cancel
    }

    private struct InlineActionBarLayout {
        let containerRect: CGRect
        let dimText: String
        let dimTextOrigin: CGPoint
        let cropButtonRect: CGRect
        let copyButtonRect: CGRect
        let cancelButtonRect: CGRect

        func hitTest(_ pt: NSPoint) -> InlineSelectionButton? {
            if cropButtonRect.contains(pt) { return .crop }
            if copyButtonRect.contains(pt) { return .copy }
            if cancelButtonRect.contains(pt) { return .cancel }
            return nil
        }
    }

    private enum SelectionDragState {
        case none
        case potentialNew(originViewPt: NSPoint, startNormPt: CGPoint, hadExistingSelection: Bool)
        case creatingNew(startNormPt: CGPoint)
        case movingExisting(startNormPt: CGPoint, initialRect: CGRect)
        case resizingHandle(handle: ResizeHandle, initialRect: CGRect)
    }

    weak var viewModel: PhotoViewerViewModel?
    var onUserActivity: (() -> Void)?

    private var cancellable: AnyCancellable?
    private var lastDragLocation: NSPoint?
    private var mouseDownOrigin: NSPoint?
    private var lastMouseViewPoint: NSPoint?
    private var isPanningImage = false
    private var selectionDragState: SelectionDragState = .none
    private var hoveredInlineButton: InlineSelectionButton?
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
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override public func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(for: pt)
    }

    private static func diagonalCursor(nwse: Bool) -> NSCursor {
        let selName = nwse ? "_windowResizeNorthWestSouthEastCursor" : "_windowResizeNorthEastSouthWestCursor"
        let sel = NSSelectorFromString(selName)
        if NSCursor.responds(to: sel),
           let unmanaged = NSCursor.perform(sel),
           let cursor = unmanaged.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }

    private func cursorForResizeHandle(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return Self.diagonalCursor(nwse: true)
        case .topRight, .bottomLeft:
            return Self.diagonalCursor(nwse: false)
        }
    }

    private func updateCursor(for pt: NSPoint) {
        guard let vm = viewModel, vm.hasImages else {
            NSCursor.arrow.set()
            return
        }

        // 1. Active drag state takes priority
        switch selectionDragState {
        case .creatingNew:
            NSCursor.crosshair.set()
            return
        case .movingExisting:
            NSCursor.closedHand.set()
            return
        case .resizingHandle(let handle, _):
            cursorForResizeHandle(handle).set()
            return
        case .potentialNew, .none:
            break
        }

        if isPanningImage {
            NSCursor.closedHand.set()
            return
        }

        // 2. If a crop selection is active, check inline buttons, 8 resize handles, and selection interior
        if vm.hasActiveSelection,
           let normRect = vm.normalizedSelectionRect,
           let imgRect = currentDisplayedImageRect() {
            if let bar = currentInlineActionBarLayout(for: vm) {
                if bar.hitTest(pt) != nil {
                    NSCursor.pointingHand.set()
                    return
                }
                if bar.containerRect.contains(pt) {
                    NSCursor.arrow.set()
                    return
                }
            }

            let selViewRect = selectionViewRect(for: normRect, in: imgRect)
            if let handle = hitTestResizeHandle(at: pt, selectionRect: selViewRect) {
                cursorForResizeHandle(handle).set()
                return
            }
            if selViewRect.contains(pt) {
                NSCursor.openHand.set()
                return
            }
            if imgRect.contains(pt) {
                NSCursor.crosshair.set()
                return
            }
        }

        // 3. If crop tool is explicitly active
        if vm.isCropToolActive, let imgRect = currentDisplayedImageRect(), imgRect.contains(pt) {
            NSCursor.crosshair.set()
            return
        }

        // 4. If zoomed in, show open hand for panning
        if vm.zoomScale > 1.01 {
            NSCursor.openHand.set()
            return
        }

        // 5. Left / Right side click navigation zones show pointingHand cursor
        if vm.canNavigate {
            let zone = navigationZone(for: pt, isFullScreen: vm.isFullScreen)
            if zone == .leftPrevious || zone == .rightNext {
                NSCursor.pointingHand.set()
                return
            }
        }

        NSCursor.arrow.set()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: - Image Geometry Helpers

    /// Returns the visual bounding box of the currently displayed image in view coordinates (bottom-left origin).
    public func currentDisplayedImageRect() -> CGRect? {
        guard let vm = viewModel,
              let cgImage = vm.currentCGImage else {
            return nil
        }
        let availW = bounds.width
        let availH = bounds.height
        guard availW > 8, availH > 8 else { return nil }

        let rawW = max(1, CGFloat(cgImage.width))
        let rawH = max(1, CGFloat(cgImage.height))
        let rotSwap = (vm.rotationDegrees % 180) != 0
        let effectiveW = rotSwap ? rawH : rawW
        let effectiveH = rotSwap ? rawW : rawH

        let fitScale = min(availW / effectiveW, availH / effectiveH)
        let zoom = vm.zoomScale
        let visualW = effectiveW * fitScale * zoom
        let visualH = effectiveH * fitScale * zoom

        let centerX = availW * 0.5 + vm.panOffset.width
        let centerY = availH * 0.5 + vm.panOffset.height

        return CGRect(
            x: centerX - visualW * 0.5,
            y: centerY - visualH * 0.5,
            width: visualW,
            height: visualH
        )
    }

    private func normalizedPoint(for viewPoint: NSPoint, in imageRect: CGRect) -> CGPoint {
        guard imageRect.width > 1, imageRect.height > 1 else { return .zero }
        let u = max(0.0, min(1.0, (viewPoint.x - imageRect.minX) / imageRect.width))
        let v = max(0.0, min(1.0, (viewPoint.y - imageRect.minY) / imageRect.height))
        return CGPoint(x: u, y: v)
    }

    private func selectionViewRect(for normalizedRect: CGRect, in imageRect: CGRect) -> CGRect {
        return CGRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        )
    }

    private func handlePosition(for handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func hitTestResizeHandle(at point: NSPoint, selectionRect: CGRect) -> ResizeHandle? {
        let hitRadius: CGFloat = 9.0
        for handle in ResizeHandle.allCases {
            let pos = handlePosition(for: handle, in: selectionRect)
            if hypot(point.x - pos.x, point.y - pos.y) <= hitRadius {
                return handle
            }
        }
        return nil
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

        if vm.autoBackgroundColorEnabled,
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

        // Draw macOS Preview-style Selection / Crop Overlay if active
        if let normRect = vm.normalizedSelectionRect,
           normRect.width > 0.003,
           normRect.height > 0.003,
           let imgRect = currentDisplayedImageRect() {
            drawSelectionOverlay(in: ctx, normRect: normRect, imageRect: imgRect, vm: vm)
        }
    }

    private func drawSelectionOverlay(
        in ctx: CGContext,
        normRect: CGRect,
        imageRect: CGRect,
        vm: PhotoViewerViewModel
    ) {
        let selRect = selectionViewRect(for: normRect, in: imageRect)

        ctx.saveGState()

        // 1. Darken the unselected portion of the image (even-odd mask)
        ctx.beginPath()
        ctx.addRect(imageRect)
        ctx.addRect(selRect)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.50).cgColor)
        ctx.drawPath(using: .eoFill)

        // 2. Subtle rule-of-thirds grid lines inside selection
        if selRect.width > 45 && selRect.height > 45 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            ctx.setLineWidth(0.75)
            for i in 1...2 {
                let frac = CGFloat(i) / 3.0
                let x = selRect.minX + selRect.width * frac
                ctx.move(to: CGPoint(x: x, y: selRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: selRect.maxY))

                let y = selRect.minY + selRect.height * frac
                ctx.move(to: CGPoint(x: selRect.minX, y: y))
                ctx.addLine(to: CGPoint(x: selRect.maxX, y: y))
            }
            ctx.strokePath()
        }

        // 3. Outer dark shadow border + inner crisp white border (visible on any background)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(selRect)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(selRect)

        // 4. Draw 8 resize handles (4 corners + 4 midpoints)
        let handleSize: CGFloat = 8.0
        for handle in ResizeHandle.allCases {
            let pos = handlePosition(for: handle, in: selRect)
            let hRect = CGRect(
                x: pos.x - handleSize * 0.5,
                y: pos.y - handleSize * 0.5,
                width: handleSize,
                height: handleSize
            )
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hRect)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(hRect)
        }

        // 5. Clickable Inline Action Bar right below (or above) the selection rectangle: [220 × 266] [Crop] [Copy] [✕]
        if let bar = currentInlineActionBarLayout(for: vm) {
            let barPath = CGPath(roundedRect: bar.containerRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(barPath)
            ctx.setFillColor(NSColor(calibratedRed: 34.0 / 255.0, green: 34.0 / 255.0, blue: 34.0 / 255.0, alpha: 0.96).cgColor)
            ctx.fillPath()

            ctx.addPath(barPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokePath()

            // Dimensions label
            let dimAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.68)
            ]
            (bar.dimText as NSString).draw(at: bar.dimTextOrigin, withAttributes: dimAttrs)

            // Crop button
            let isCropHovered = (hoveredInlineButton == .crop)
            drawInlineButton(
                in: ctx,
                rect: bar.cropButtonRect,
                title: "Crop",
                bgColor: isCropHovered
                    ? NSColor.controlAccentColor.blended(withFraction: 0.18, of: .white) ?? NSColor.controlAccentColor
                    : NSColor.controlAccentColor,
                textColor: .white,
                isBold: true
            )

            // Copy button
            let isCopyHovered = (hoveredInlineButton == .copy)
            drawInlineButton(
                in: ctx,
                rect: bar.copyButtonRect,
                title: "Copy",
                bgColor: NSColor(calibratedWhite: isCopyHovered ? 0.34 : 0.25, alpha: 1.0),
                textColor: .white.withAlphaComponent(0.92),
                isBold: false
            )

            // Cancel (✕) button
            let isCancelHovered = (hoveredInlineButton == .cancel)
            drawInlineButton(
                in: ctx,
                rect: bar.cancelButtonRect,
                title: "✕",
                bgColor: NSColor(calibratedWhite: isCancelHovered ? 0.34 : 0.22, alpha: 1.0),
                textColor: .white.withAlphaComponent(0.85),
                isBold: false
            )
        }

        ctx.restoreGState()
    }

    private func drawInlineButton(
        in ctx: CGContext,
        rect: CGRect,
        title: String,
        bgColor: NSColor,
        textColor: NSColor,
        isBold: Bool
    ) {
        let btnPath = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(btnPath)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fillPath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isBold ? .semibold : .medium),
            .foregroundColor: textColor
        ]
        let str = title as NSString
        let size = str.size(withAttributes: attrs)
        let textPt = NSPoint(
            x: rect.midX - size.width * 0.5,
            y: rect.midY - size.height * 0.5
        )
        str.draw(at: textPt, withAttributes: attrs)
    }

    private func currentInlineActionBarLayout(for vm: PhotoViewerViewModel) -> InlineActionBarLayout? {
        guard let normRect = vm.normalizedSelectionRect,
              vm.hasActiveSelection,
              let imgRect = currentDisplayedImageRect() else {
            return nil
        }

        let selRect = selectionViewRect(for: normRect, in: imgRect)
        let dimText = vm.selectedPixelDimensionsText
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]
        let dimSize = (dimText as NSString).size(withAttributes: dimAttrs)

        let padX: CGFloat = 8
        let gap: CGFloat = 6
        let barH: CGFloat = 32
        let btnH: CGFloat = 22
        let cropW: CGFloat = 52
        let copyW: CGFloat = 50
        let cancelW: CGFloat = 24

        let barW = padX + dimSize.width + 6 + cropW + gap + copyW + gap + cancelW + padX
        let barX = max(8, min(bounds.width - barW - 8, selRect.midX - barW * 0.5))

        let belowY = selRect.minY - barH - 8
        let aboveY = selRect.maxY + 8
        let barY: CGFloat
        if belowY >= 8 {
            barY = belowY
        } else if aboveY + barH <= bounds.height - 8 {
            barY = aboveY
        } else {
            barY = max(8, selRect.minY + 8)
        }

        let containerRect = CGRect(x: barX, y: barY, width: barW, height: barH)
        let btnY = barY + (barH - btnH) * 0.5

        let dimOrigin = CGPoint(
            x: barX + padX,
            y: barY + (barH - dimSize.height) * 0.5
        )
        let cropX = barX + padX + dimSize.width + 8
        let cropRect = CGRect(x: cropX, y: btnY, width: cropW, height: btnH)
        let copyRect = CGRect(x: cropRect.maxX + gap, y: btnY, width: copyW, height: btnH)
        let cancelRect = CGRect(x: copyRect.maxX + gap, y: btnY, width: cancelW, height: btnH)

        return InlineActionBarLayout(
            containerRect: containerRect,
            dimText: dimText,
            dimTextOrigin: dimOrigin,
            cropButtonRect: cropRect,
            copyButtonRect: copyRect,
            cancelButtonRect: cancelRect
        )
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

    public func navigationZone(for point: NSPoint, isFullScreen: Bool) -> ClickZone {
        return Self.navigationZone(for: point, in: bounds.size, isFullScreen: isFullScreen)
    }

    public static func navigationZone(for point: NSPoint, in size: NSSize, isFullScreen: Bool) -> ClickZone {
        let w = size.width
        let h = size.height
        guard w > 100, h > 60 else { return .center }

        if !isFullScreen {
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
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(for: pt)

        guard let vm = viewModel else { return }

        if vm.hasActiveSelection, let bar = currentInlineActionBarLayout(for: vm) {
            let hit = bar.hitTest(pt)
            if hoveredInlineButton != hit {
                hoveredInlineButton = hit
                needsDisplay = true
            }
        } else if hoveredInlineButton != nil {
            hoveredInlineButton = nil
            needsDisplay = true
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        onUserActivity?()
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(for: pt)
    }

    override public func mouseExited(with event: NSEvent) {
        if hoveredInlineButton != nil {
            hoveredInlineButton = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let vm = viewModel else { return }

        let pt = convert(event.locationInWindow, from: nil)
        mouseDownOrigin = pt
        selectionDragState = .none

        // 0. If an inline action button ([Crop] [Copy] [✕]) under the selection box was clicked, fire it immediately!
        if vm.hasActiveSelection, let bar = currentInlineActionBarLayout(for: vm) {
            if let hitBtn = bar.hitTest(pt) {
                hoveredInlineButton = nil
                switch hitBtn {
                case .crop:
                    vm.cropToSelection()
                case .copy:
                    vm.copyImageToClipboard()
                case .cancel:
                    vm.clearSelection()
                }
                needsDisplay = true
                return
            }
            // Clicking on the action bar container background shouldn't dismiss the selection
            if bar.containerRect.contains(pt) {
                return
            }
        }

        // 1. If a selection rectangle is currently active, check if user clicked a resize handle or inside it
        if let normRect = vm.normalizedSelectionRect,
           vm.hasActiveSelection,
           let imgRect = currentDisplayedImageRect() {
            let selViewRect = selectionViewRect(for: normRect, in: imgRect)

            if let handle = hitTestResizeHandle(at: pt, selectionRect: selViewRect) {
                selectionDragState = .resizingHandle(handle: handle, initialRect: normRect)
                return
            }

            if selViewRect.contains(pt) {
                if event.clickCount == 2 {
                    vm.cropToSelection()
                    return
                }
                let startNorm = normalizedPoint(for: pt, in: imgRect)
                selectionDragState = .movingExisting(startNormPt: startNorm, initialRect: normRect)
                return
            }
        }

        // 2. If zoomed in (and not in explicit crop tool mode), drag to pan
        if vm.zoomScale > 1.01 && !vm.isCropToolActive {
            isPanningImage = true
            lastDragLocation = pt
            NSCursor.closedHand.push()
            return
        }

        // 3. If clicking inside the displayed image:
        //    - Dragging draws a macOS Preview-style selection/crop rectangle!
        //    - Releasing without dragging navigates (if in left/right zone), clears selection, or toggles fullscreen on double-click!
        if let imgRect = currentDisplayedImageRect(), imgRect.contains(pt) {
            let startNorm = normalizedPoint(for: pt, in: imgRect)
            selectionDragState = .potentialNew(
                originViewPt: pt,
                startNormPt: startNorm,
                hadExistingSelection: vm.hasActiveSelection
            )
            return
        }

        // 4. Clicked outside the displayed image (in the grey letterbox/pillarbox margin):
        if vm.hasActiveSelection {
            vm.clearSelection()
            needsDisplay = true
            return
        }

        let zone = navigationZone(for: pt, isFullScreen: vm.isFullScreen)
        if vm.canNavigate {
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

        if event.clickCount == 2 {
            vm.resetZoomToFit()
            vm.toggleFullScreen()
            return
        }

        if !vm.isFullScreen {
            window?.performDrag(with: event)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        onUserActivity?()
        guard let vm = viewModel else { return }
        let current = convert(event.locationInWindow, from: nil)
        lastMouseViewPoint = current
        updateCursor(for: current)
        let isShiftDown = event.modifierFlags.contains(.shift)

        // Handle active or potential selection box drag
        switch selectionDragState {
        case .potentialNew(let originPt, let startNorm, _):
            if hypot(current.x - originPt.x, current.y - originPt.y) >= 4.0,
               let imgRect = currentDisplayedImageRect() {
                selectionDragState = .creatingNew(startNormPt: startNorm)
                updateCreatingSelection(
                    from: startNorm,
                    currentViewPt: current,
                    imageRect: imgRect,
                    constrainToSquare: isShiftDown,
                    vm: vm
                )
            }
            return

        case .creatingNew(let startNorm):
            if let imgRect = currentDisplayedImageRect() {
                updateCreatingSelection(
                    from: startNorm,
                    currentViewPt: current,
                    imageRect: imgRect,
                    constrainToSquare: isShiftDown,
                    vm: vm
                )
            }
            return

        case .movingExisting(let startNorm, let initialRect):
            if let imgRect = currentDisplayedImageRect() {
                let curNorm = normalizedPoint(for: current, in: imgRect)
                let du = curNorm.x - startNorm.x
                let dv = curNorm.y - startNorm.y
                let newX = max(0.0, min(1.0 - initialRect.width, initialRect.minX + du))
                let newY = max(0.0, min(1.0 - initialRect.height, initialRect.minY + dv))
                vm.normalizedSelectionRect = CGRect(
                    x: newX,
                    y: newY,
                    width: initialRect.width,
                    height: initialRect.height
                )
                needsDisplay = true
            }
            return

        case .resizingHandle(let handle, let initialRect):
            if let imgRect = currentDisplayedImageRect() {
                updateResizingSelection(
                    handle: handle,
                    initialRect: initialRect,
                    currentViewPt: current,
                    imageRect: imgRect,
                    constrainToSquare: isShiftDown,
                    vm: vm
                )
            }
            return

        case .none:
            break
        }

        guard isPanningImage, let last = lastDragLocation else { return }
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

    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let vm = viewModel,
              let current = lastMouseViewPoint,
              let imgRect = currentDisplayedImageRect() else {
            return
        }
        let isShiftDown = event.modifierFlags.contains(.shift)

        switch selectionDragState {
        case .creatingNew(let startNorm):
            updateCreatingSelection(
                from: startNorm,
                currentViewPt: current,
                imageRect: imgRect,
                constrainToSquare: isShiftDown,
                vm: vm
            )
        case .resizingHandle(let handle, let initialRect):
            updateResizingSelection(
                handle: handle,
                initialRect: initialRect,
                currentViewPt: current,
                imageRect: imgRect,
                constrainToSquare: isShiftDown,
                vm: vm
            )
        default:
            break
        }
    }

    override public func mouseUp(with event: NSEvent) {
        guard let vm = viewModel else { return }
        let pt = convert(event.locationInWindow, from: nil)

        switch selectionDragState {
        case .potentialNew(_, _, let hadExistingSelection):
            selectionDragState = .none
            // User clicked on the image without dragging:
            if hadExistingSelection {
                vm.clearSelection()
                needsDisplay = true
                return
            }
            // Check left/right side click navigation first
            let zone = navigationZone(for: pt, isFullScreen: vm.isFullScreen)
            if vm.canNavigate {
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
            // Center double-click toggles Fullscreen
            if event.clickCount == 2 {
                vm.resetZoomToFit()
                vm.toggleFullScreen()
                return
            }
            return

        case .creatingNew, .movingExisting, .resizingHandle:
            selectionDragState = .none
            if let rect = vm.normalizedSelectionRect, (rect.width < 0.01 || rect.height < 0.01) {
                vm.clearSelection()
            }
            updateCursor(for: pt)
            needsDisplay = true
            return

        case .none:
            break
        }

        if isPanningImage {
            isPanningImage = false
            lastDragLocation = nil
            NSCursor.pop()

            if vm.canNavigate, let origin = mouseDownOrigin {
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

    /// Computes the normalized selection CGRect (0...1 in image coordinates) from an anchor normalized point
    /// and a current view point. When `constrainToSquare` is true (Shift key held, like Photoshop),
    /// constrains the selection to a true 1:1 visual & pixel square anchored at `startNorm`.
    public static func computeSelectionNormalizedRect(
        from startNorm: CGPoint,
        currentViewPt: NSPoint,
        imageRect: CGRect,
        constrainToSquare: Bool
    ) -> CGRect {
        guard imageRect.width > 1, imageRect.height > 1 else { return .zero }

        let anchorX = imageRect.minX + startNorm.x * imageRect.width
        let anchorY = imageRect.minY + startNorm.y * imageRect.height
        let clampedX = max(imageRect.minX, min(imageRect.maxX, currentViewPt.x))
        let clampedY = max(imageRect.minY, min(imageRect.maxY, currentViewPt.y))

        var targetX = clampedX
        var targetY = clampedY

        if constrainToSquare {
            let dx = clampedX - anchorX
            let dy = clampedY - anchorY
            let signX: CGFloat = dx >= 0 ? 1.0 : -1.0
            let signY: CGFloat = dy >= 0 ? 1.0 : -1.0

            let desiredSide = max(abs(dx), abs(dy))
            let maxAvailX = signX >= 0 ? (imageRect.maxX - anchorX) : (anchorX - imageRect.minX)
            let maxAvailY = signY >= 0 ? (imageRect.maxY - anchorY) : (anchorY - imageRect.minY)
            let clampedSide = min(desiredSide, min(maxAvailX, maxAvailY))

            targetX = anchorX + signX * clampedSide
            targetY = anchorY + signY * clampedSide
        }

        let minViewX = min(anchorX, targetX)
        let maxViewX = max(anchorX, targetX)
        let minViewY = min(anchorY, targetY)
        let maxViewY = max(anchorY, targetY)

        let uMin = max(0.0, min(1.0, (minViewX - imageRect.minX) / imageRect.width))
        let uMax = max(0.0, min(1.0, (maxViewX - imageRect.minX) / imageRect.width))
        let vMin = max(0.0, min(1.0, (minViewY - imageRect.minY) / imageRect.height))
        let vMax = max(0.0, min(1.0, (maxViewY - imageRect.minY) / imageRect.height))

        return CGRect(
            x: uMin,
            y: vMin,
            width: max(0.0, uMax - uMin),
            height: max(0.0, vMax - vMin)
        )
    }

    private func updateCreatingSelection(
        from startNorm: CGPoint,
        currentViewPt: NSPoint,
        imageRect: CGRect,
        constrainToSquare: Bool,
        vm: PhotoViewerViewModel
    ) {
        vm.normalizedSelectionRect = Self.computeSelectionNormalizedRect(
            from: startNorm,
            currentViewPt: currentViewPt,
            imageRect: imageRect,
            constrainToSquare: constrainToSquare
        )
        needsDisplay = true
    }

    private func updateResizingSelection(
        handle: ResizeHandle,
        initialRect: CGRect,
        currentViewPt: NSPoint,
        imageRect: CGRect,
        constrainToSquare: Bool,
        vm: PhotoViewerViewModel
    ) {
        // When Shift is held on a corner handle, anchor at the opposite corner and constrain to a 1:1 square
        if constrainToSquare {
            switch handle {
            case .topLeft:
                let anchor = CGPoint(x: initialRect.maxX, y: initialRect.minY)
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            case .topRight:
                let anchor = CGPoint(x: initialRect.minX, y: initialRect.minY)
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            case .bottomRight:
                let anchor = CGPoint(x: initialRect.minX, y: initialRect.maxY)
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            case .bottomLeft:
                let anchor = CGPoint(x: initialRect.maxX, y: initialRect.maxY)
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            case .left, .right:
                let anchor = CGPoint(
                    x: handle == .left ? initialRect.maxX : initialRect.minX,
                    y: initialRect.minY
                )
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            case .top, .bottom:
                let anchor = CGPoint(
                    x: initialRect.minX,
                    y: handle == .bottom ? initialRect.maxY : initialRect.minY
                )
                updateCreatingSelection(from: anchor, currentViewPt: currentViewPt, imageRect: imageRect, constrainToSquare: true, vm: vm)
                return
            }
        }

        let curNorm = normalizedPoint(for: currentViewPt, in: imageRect)
        var minX = initialRect.minX
        var maxX = initialRect.maxX
        var minY = initialRect.minY
        var maxY = initialRect.maxY
        let minSize: CGFloat = 0.02

        switch handle {
        case .topLeft:
            minX = min(curNorm.x, maxX - minSize)
            maxY = max(curNorm.y, minY + minSize)
        case .top:
            maxY = max(curNorm.y, minY + minSize)
        case .topRight:
            maxX = max(curNorm.x, minX + minSize)
            maxY = max(curNorm.y, minY + minSize)
        case .right:
            maxX = max(curNorm.x, minX + minSize)
        case .bottomRight:
            maxX = max(curNorm.x, minX + minSize)
            minY = min(curNorm.y, maxY - minSize)
        case .bottom:
            minY = min(curNorm.y, maxY - minSize)
        case .bottomLeft:
            minX = min(curNorm.x, maxX - minSize)
            minY = min(curNorm.y, maxY - minSize)
        case .left:
            minX = min(curNorm.x, maxX - minSize)
        }

        vm.normalizedSelectionRect = CGRect(
            x: max(0.0, minX),
            y: max(0.0, minY),
            width: min(1.0, maxX) - max(0.0, minX),
            height: min(1.0, maxY) - max(0.0, minY)
        )
        needsDisplay = true
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

        if vm.hasActiveSelection {
            let cropNow = NSMenuItem(title: "Crop", action: #selector(ctxCropToSelection), keyEquivalent: "k")
            cropNow.target = self
            menu.addItem(cropNow)

            let copySel = NSMenuItem(title: "Copy Selection", action: #selector(ctxCopyImage), keyEquivalent: "c")
            copySel.target = self
            menu.addItem(copySel)

            let clearSel = NSMenuItem(title: "Cancel Selection", action: #selector(ctxClearSelection), keyEquivalent: "")
            clearSel.target = self
            menu.addItem(clearSel)

            menu.addItem(.separator())
        } else {
            let startCrop = NSMenuItem(title: "Crop Image", action: #selector(ctxToggleCropMode), keyEquivalent: "k")
            startCrop.target = self
            menu.addItem(startCrop)
        }

        if vm.canUndoEdit {
            let undoItem = NSMenuItem(title: "Undo Crop", action: #selector(ctxUndoEdit), keyEquivalent: "z")
            undoItem.target = self
            menu.addItem(undoItem)
            menu.addItem(.separator())
        }

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
    @objc private func ctxToggleCropMode() { viewModel?.toggleCropMode() }
    @objc private func ctxCropToSelection() { viewModel?.cropToSelection() }
    @objc private func ctxClearSelection() { viewModel?.clearSelection() }
    @objc private func ctxUndoEdit() { viewModel?.undoLastEdit() }
    @objc private func ctxFullScreen() { viewModel?.toggleFullScreen() }
    @objc private func ctxFit() { viewModel?.resetZoomToFit() }
    @objc private func ctxActualSize() { viewModel?.toggleActualSizeOrFit() }
    @objc private func ctxRotateLeft() { viewModel?.rotateLeft() }
    @objc private func ctxRotateRight() { viewModel?.rotateRight() }
    @objc private func ctxFlip() { viewModel?.toggleFlipHorizontal() }
    @objc private func ctxToggleAutoBackground() { viewModel?.toggleAutoBackgroundColor() }
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
