import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var viewModel: PhotoViewerViewModel
    @State private var isDropTargeted: Bool = false

    // Exact Windows 11 Photos dark grey colors sampled from reference screenshots
    private static let windowsCanvasGrey = Color(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 32.0 / 255.0) // #202020
    private static let windowsTopBarGrey = Color(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 32.0 / 255.0) // #202020
    private static let windowsBottomBarGrey = Color(red: 39.0 / 255.0, green: 39.0 / 255.0, blue: 39.0 / 255.0) // #272727
    private static let windowsButtonBgGrey = Color(red: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0) // #2E2E2E

    public init(viewModel: PhotoViewerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 1. Dedicated Top Bar (Windowed mode only — never overlaps the photo)
                if !viewModel.isFullScreen {
                    windowsTopBar
                }

                // 2. Main Photo Canvas Area (Strictly between top bar and bottom bar)
                ZStack {
                    canvasBackgroundLayer

                    if viewModel.hasImages {
                        InteractiveImageCanvas(
                            viewModel: viewModel,
                            onUserActivity: {}
                        )
                    } else {
                        emptyWelcomeState
                    }

                    // Subtle Toast Notification (Windowed mode only)
                    if !viewModel.isFullScreen, let toast = viewModel.statusToast {
                        VStack {
                            Text(toast)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Self.windowsBottomBarGrey)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                                .padding(.top, 12)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 3. Dedicated Bottom Status & Zoom Bar (Windowed mode only — never overlaps the photo)
                if !viewModel.isFullScreen && viewModel.hasImages {
                    windowsBottomBar
                }
            }
            .ignoresSafeArea()

            // Drag & Drop Highlight Border
            if isDropTargeted && !viewModel.isFullScreen {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2.5)
                    .background(Color.accentColor.opacity(0.06))
                    .padding(4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            ensureTrafficLightsVisible()
        }
    }

    // MARK: - Canvas Background Layer

    @ViewBuilder
    private var canvasBackgroundLayer: some View {
        if viewModel.autoBackgroundColorEnabled && viewModel.hasImages,
           let bgColor = viewModel.detectedBackgroundColor {
            Color(nsColor: bgColor)
        } else {
            Self.windowsCanvasGrey
        }
    }

    // MARK: - Windows 11 Photos Top Toolbar

    private var windowsTopBar: some View {
        ZStack {
            // Centered Filename (click to rename inline; never overlaps left/right buttons or the photo)
            if viewModel.hasImages {
                EditableTopBarFilenameView(viewModel: viewModel)
                    .padding(.horizontal, 260)
            } else {
                Text("Simple Photos")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .allowsHitTesting(false)
            }

            HStack(spacing: 4) {
                // Space for macOS close/minimize/zoom window buttons
                Spacer()
                    .frame(width: 72)

                if viewModel.hasImages {
                    // Crop Icon (or drag directly on image; action buttons appear right below selection)
                    WinBarIconButton(
                        systemName: "crop",
                        isActive: viewModel.isCropToolActive || viewModel.hasActiveSelection,
                        help: "Crop"
                    ) {
                        viewModel.toggleCropMode()
                    }

                    if viewModel.canUndoEdit {
                        WinBarIconButton(
                            systemName: "arrow.uturn.backward",
                            help: "Undo Crop"
                        ) {
                            viewModel.undoLastEdit()
                        }
                    }

                    // Rotate Right (matching Windows Photos rotate icon)
                    WinBarIconButton(
                        systemName: "rotate.right",
                        help: "Rotate Right (] or ⌘R)"
                    ) {
                        viewModel.rotateRight()
                    }

                    // Delete / Move to Trash
                    WinBarIconButton(
                        systemName: "trash",
                        isDestructive: true,
                        help: "Move to Trash (Delete)"
                    ) {
                        viewModel.moveCurrentImageToTrash()
                    }

                    // Search in Yandex
                    WinBarIconButton(
                        systemName: "magnifyingglass",
                        isActive: viewModel.isSearchingYandex,
                        isDisabled: viewModel.isSearchingYandex,
                        help: "Search Image in Yandex (Y)"
                    ) {
                        viewModel.searchCurrentImageInYandex()
                    }

                    // Copy Image
                    WinBarIconButton(
                        systemName: "doc.on.doc",
                        help: "Copy Image to Clipboard (⌘C)"
                    ) {
                        viewModel.copyImageToClipboard()
                    }
                }

                // More Options Button (...) — uses WinBarIconButton + NSMenu so the entire 30x26 box (including edges) is 100% clickable
                WinBarIconButton(
                    systemName: "ellipsis",
                    help: "More Options"
                ) {
                    presentMoreOptionsMenu()
                }

                Spacer()

                // Right side button (matching Windows Photos "Open with" / Finder button)
                if viewModel.hasImages {
                    Button {
                        viewModel.revealInFinder()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Show in Finder")
                                .font(.system(size: 11.5, weight: .regular))
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Self.windowsButtonBgGrey)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursorOnHover()
                    .help("Reveal in Finder (⇧⌘R)")
                    .padding(.trailing, 12)
                } else {
                    Button {
                        viewModel.presentOpenPanel()
                    } label: {
                        Text("Open…")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Self.windowsButtonBgGrey)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursorOnHover()
                    .padding(.trailing, 12)
                }
            }
        }
        .frame(height: 42)
        .background(Self.windowsTopBarGrey)
    }

    // MARK: - Windows 11 Photos Bottom Status & Zoom Bar

    private var windowsBottomBar: some View {
        ZStack {
            // Center action icons (Info & Actual Size / Fit, just like Windows 11 Photos)
            HStack(spacing: 6) {
                WinBarIconButton(
                    systemName: "info.circle",
                    isActive: viewModel.showMetadataPopover,
                    help: "File Info & Options (I)"
                ) {
                    viewModel.showMetadataPopover.toggle()
                }
                .popover(isPresented: $viewModel.showMetadataPopover, arrowEdge: .top) {
                    metadataPopoverView
                }

                WinBarIconButton(
                    systemName: "plus.viewfinder",
                    isActive: abs(viewModel.zoomScale - 1.0) > 0.02,
                    help: "Toggle Actual Size 1:1 / Fit (1)"
                ) {
                    viewModel.toggleActualSizeOrFit()
                }
            }

            HStack(spacing: 12) {
                // Bottom-Left: Format, Dimensions, File Size, Folder Index (removed video-like button)
                HStack(spacing: 12) {
                    if !viewModel.metadata.fileExtensionBadge.isEmpty {
                        Text(viewModel.metadata.fileExtensionBadge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    if !viewModel.metadata.dimensionsString.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.white.opacity(0.55))
                            Text(viewModel.metadata.dimensionsString.replacingOccurrences(of: "×", with: "x"))
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    }

                    if !viewModel.metadata.fileSizeFormatted.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.white.opacity(0.55))
                            Text(viewModel.metadata.fileSizeFormatted)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    }

                    if viewModel.canNavigate {
                        Text(viewModel.positionText)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .padding(.leading, 10)

                Spacer()

                // Bottom-Right: Fit button, Zoom Percentage dropdown, Zoom Out, Slider, Zoom In, Fullscreen
                HStack(spacing: 6) {
                    WinBarIconButton(
                        systemName: "rectangle.arrowtriangle.2.inward",
                        isDisabled: abs(viewModel.zoomScale - 1.0) < 0.01 && viewModel.panOffset == .zero,
                        help: "Fit to Window (0)"
                    ) {
                        viewModel.resetZoomToFit()
                    }

                    Button {
                        presentZoomPresetsMenu()
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.displayZoomPercentageText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(minWidth: 52)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Self.windowsButtonBgGrey)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursorOnHover()
                    .help("Select Zoom Level")

                    WinBarIconButton(
                        systemName: "minus.magnifyingglass",
                        help: "Zoom Out (-)"
                    ) {
                        viewModel.zoomOut()
                    }

                    Slider(
                        value: Binding(
                            get: { min(max(Double(viewModel.zoomScale), 0.25), 4.0) },
                            set: { viewModel.setZoom(CGFloat($0)) }
                        ),
                        in: 0.25...4.0
                    )
                    .controlSize(.mini)
                    .frame(width: 88)

                    WinBarIconButton(
                        systemName: "plus.magnifyingglass",
                        help: "Zoom In (+)"
                    ) {
                        viewModel.zoomIn()
                    }

                    WinBarIconButton(
                        systemName: "arrow.up.left.and.arrow.down.right",
                        help: "Fullscreen (Double-Click or F)"
                    ) {
                        viewModel.toggleFullScreen()
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .frame(height: 34)
        .background(Self.windowsBottomBarGrey)
    }

    // MARK: - Metadata & Options Popover

    private var metadataPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(viewModel.metadata.filename)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if !viewModel.metadata.dimensionsString.isEmpty {
                    metadataRow("Dimensions", "\(viewModel.metadata.dimensionsString) px")
                }
                if !viewModel.metadata.fileSizeFormatted.isEmpty {
                    metadataRow("File Size", viewModel.metadata.fileSizeFormatted)
                }
                if !viewModel.metadata.formatName.isEmpty {
                    metadataRow("Format", viewModel.metadata.formatName)
                }
                if !viewModel.metadata.colorModel.isEmpty {
                    let depthText = viewModel.metadata.bitDepth > 0 ? " (\(viewModel.metadata.bitDepth)-bit)" : ""
                    metadataRow("Color", "\(viewModel.metadata.colorModel)\(depthText)")
                }
                if viewModel.metadata.isAnimated {
                    metadataRow("Frames", "\(viewModel.metadata.frameCount) frames")
                }
                if !viewModel.metadata.cameraMakeModel.isEmpty {
                    metadataRow("Camera", viewModel.metadata.cameraMakeModel)
                }
                if !viewModel.metadata.exposureInfo.isEmpty {
                    metadataRow("Exposure", viewModel.metadata.exposureInfo)
                }
                if !viewModel.metadata.dateString.isEmpty {
                    metadataRow("Date", viewModel.metadata.dateString)
                }
                metadataRow("Folder Index", viewModel.positionText)
            }
            .font(.system(size: 12))

            Divider()

            Toggle(isOn: $viewModel.autoBackgroundColorEnabled) {
                Text("Automatic Background Color")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Default Image Viewer")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isDefaultImageViewer {
                        Label("Simple Photos", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text("macOS Preview / Other")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.setAsDefaultForAllImages()
                    } label: {
                        Text("Set Simple Photos")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isUpdatingDefaultViewer)

                    Button {
                        viewModel.restorePreviewAsDefaultForAllImages()
                    } label: {
                        Text("Restore Preview")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isUpdatingDefaultViewer)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    viewModel.revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                }

                Spacer()

                Button {
                    viewModel.copyFilePathToClipboard()
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
        }
        .padding(14)
        .frame(width: 295)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Empty / Welcome State

    private var emptyWelcomeState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))

            VStack(spacing: 6) {
                Text("Simple Photos")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Drop an image or folder here, or open any photo.\nSibling photos in the same folder load automatically for ← / → browsing.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.presentOpenPanel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("Open Image or Folder…")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    SampleGalleryGenerator.openDemoGallery(in: viewModel)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack")
                        Text("Try Sample Photos")
                    }
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Self.windowsButtonBgGrey)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.setAsDefaultForAllImages()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isDefaultImageViewer ? "checkmark.circle.fill" : "photo.badge.checkmark")
                            .foregroundStyle(viewModel.isDefaultImageViewer ? .green : .white.opacity(0.85))
                        Text(viewModel.isDefaultImageViewer ? "Default for All Images (Active)" : "Set as Default for All Images")
                    }
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Self.windowsButtonBgGrey)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isUpdatingDefaultViewer)

                Button {
                    viewModel.restorePreviewAsDefaultForAllImages()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward.circle")
                        Text("Restore Preview as Default")
                    }
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Self.windowsButtonBgGrey.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isUpdatingDefaultViewer)
            }
        }
        .padding(32)
    }

    private func ensureTrafficLightsVisible() {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            return
        }
        for btnType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(btnType)?.alphaValue = 1.0
        }
    }

    // MARK: - Native Popup Menus for Full-Hitbox Toolbar Buttons

    private func presentMoreOptionsMenu() {
        let menu = NSMenu(title: "More Options")

        menu.addItem(ActionMenuItem(title: "Open Image or Folder…") { [weak viewModel] in
            viewModel?.presentOpenPanel()
        })

        if viewModel.hasImages {
            menu.addItem(.separator())

            menu.addItem(ActionMenuItem(title: "Rename File…") { [weak viewModel] in
                viewModel?.beginRenamingCurrentImage()
            })

            menu.addItem(ActionMenuItem(title: "Rotate Left") { [weak viewModel] in
                viewModel?.rotateLeft()
            })

            menu.addItem(ActionMenuItem(title: "Flip Horizontally") { [weak viewModel] in
                viewModel?.toggleFlipHorizontal()
            })

            menu.addItem(ActionMenuItem(title: "Copy File Path") { [weak viewModel] in
                viewModel?.copyFilePathToClipboard()
            })
        }

        menu.addItem(.separator())

        let autoBg = ActionMenuItem(title: "Automatic Background Color") { [weak viewModel] in
            viewModel?.toggleAutoBackgroundColor()
        }
        autoBg.state = viewModel.autoBackgroundColorEnabled ? .on : .off
        menu.addItem(autoBg)

        let pinTop = ActionMenuItem(title: "Pin Window Always on Top") { [weak viewModel] in
            viewModel?.isAlwaysOnTop.toggle()
        }
        pinTop.state = viewModel.isAlwaysOnTop ? .on : .off
        menu.addItem(pinTop)

        menu.addItem(.separator())

        let setDef = ActionMenuItem(title: "Set as Default for All Images") { [weak viewModel] in
            viewModel?.setAsDefaultForAllImages()
        }
        setDef.state = viewModel.isDefaultImageViewer ? .on : .off
        menu.addItem(setDef)

        menu.addItem(ActionMenuItem(title: "Restore Preview as Default Viewer") { [weak viewModel] in
            viewModel?.restorePreviewAsDefaultForAllImages()
        })

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func presentZoomPresetsMenu() {
        let menu = NSMenu(title: "Zoom Level")

        let fitItem = ActionMenuItem(title: "Fit to window") { [weak viewModel] in
            viewModel?.resetZoomToFit()
        }
        if abs(viewModel.zoomScale - 1.0) < 0.01 && viewModel.panOffset == .zero {
            fitItem.state = .on
        }
        menu.addItem(fitItem)
        menu.addItem(.separator())

        for pct in PhotoViewerViewModel.zoomPercentagePresets {
            let item = ActionMenuItem(title: "\(pct)%") { [weak viewModel] in
                viewModel?.setDisplayZoomPercentage(pct)
            }
            if viewModel.displayZoomPercentageText == "\(pct)%" && abs(viewModel.zoomScale - 1.0) >= 0.01 {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - SwiftUI Drop Fallback

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        collectedURLs.append(url)
                    } else if let url = item as? URL {
                        collectedURLs.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !collectedURLs.isEmpty {
                viewModel.open(urls: collectedURLs)
            }
        }
        return true
    }
}

// MARK: - Windows 11 Style Flat Toolbar Button

private struct WinBarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    var isDestructive: Bool = false
    let help: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 26)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .onHover { hovering in
            isHovered = hovering
            if !isDisabled {
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return .white.opacity(0.28)
        }
        if isDestructive && isHovered {
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
        if isActive {
            return Color.accentColor
        }
        return .white.opacity(isHovered ? 0.98 : 0.82)
    }

    private var backgroundColor: Color {
        if isDisabled {
            return .clear
        }
        if isActive {
            return Color.white.opacity(0.12)
        }
        if isHovered {
            return Color.white.opacity(0.08)
        }
        return .clear
    }
}

private extension View {
    func pointerCursorOnHover() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - Inline Top-Bar Filename Editor & Menu Helper

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

private struct EditableTopBarFilenameView: View {
    @ObservedObject var viewModel: PhotoViewerViewModel

    var body: some View {
        PlainFilenameTextField(
            filename: viewModel.metadata.filename,
            isEditing: $viewModel.isRenamingFilename,
            onCommit: { newText in
                viewModel.commitRenameCurrentImage(to: newText)
            },
            onCancel: {
                viewModel.cancelRenamingCurrentImage()
            }
        )
        .frame(maxWidth: 360, maxHeight: 22)
    }
}

public final class FilenameNSTextField: NSTextField {
    var onStartEditing: (() -> Void)?

    /// Returns the tight bounding box around the actual visible text characters (not the full 360pt layout container).
    public func actualTextRect() -> NSRect {
        let currentStr = (currentEditor()?.string ?? stringValue) as NSString
        let fontToUse = self.font ?? NSFont.systemFont(ofSize: 12, weight: .regular)
        let measuredWidth = ceil(currentStr.size(withAttributes: [.font: fontToUse]).width)
        let tightWidth = max(24, min(bounds.width, measuredWidth + 10))
        let x = bounds.midX - tightWidth * 0.5
        return NSRect(x: x, y: bounds.minY, width: tightWidth, height: bounds.height)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        // Convert point from superview coordinates to local bounds
        let localPt = convert(point, from: superview)
        guard actualTextRect().contains(localPt) else {
            return nil
        }
        return super.hitTest(point)
    }

    override public func mouseDown(with event: NSEvent) {
        let localPt = convert(event.locationInWindow, from: nil)
        guard actualTextRect().contains(localPt) else {
            if currentEditor() != nil {
                window?.makeFirstResponder(nil)
            }
            window?.performDrag(with: event)
            return
        }

        let wasEditing = (currentEditor() != nil)
        onStartEditing?()
        super.mouseDown(with: event)

        // On first click into the filename, select the stem (before the file extension) for fast renaming
        if !wasEditing, let editor = currentEditor() {
            let full = stringValue as NSString
            let ext = full.pathExtension
            if !ext.isEmpty && full.length > ext.count + 1 {
                editor.selectedRange = NSRange(location: 0, length: full.length - ext.count - 1)
            } else {
                editor.selectAll(nil)
            }
        }
    }
}

private struct PlainFilenameTextField: NSViewRepresentable {
    var filename: String
    @Binding var isEditing: Bool
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FilenameNSTextField {
        let tf = FilenameNSTextField(string: filename)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        tf.textColor = NSColor.white.withAlphaComponent(0.88)
        tf.alignment = .center
        tf.delegate = context.coordinator
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.cell?.lineBreakMode = .byTruncatingMiddle
        tf.refusesFirstResponder = true

        tf.onStartEditing = { [weak tf, weak coord = context.coordinator] in
            guard let tf, let coord else { return }
            tf.refusesFirstResponder = false
            coord.didCancel = false
            coord.parent.isEditing = true
            tf.window?.makeFirstResponder(tf)
        }
        return tf
    }

    func updateNSView(_ nsView: FilenameNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.currentEditor() == nil {
            if nsView.stringValue != filename {
                nsView.stringValue = filename
            }
            nsView.refusesFirstResponder = !isEditing
            if isEditing {
                DispatchQueue.main.async {
                    nsView.refusesFirstResponder = false
                    nsView.window?.makeFirstResponder(nsView)
                    if let editor = nsView.currentEditor() {
                        let full = nsView.stringValue as NSString
                        let ext = full.pathExtension
                        if !ext.isEmpty && full.length > ext.count + 1 {
                            editor.selectedRange = NSRange(location: 0, length: full.length - ext.count - 1)
                        } else {
                            editor.selectAll(nil)
                        }
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainFilenameTextField
        var didCancel = false

        init(_ parent: PlainFilenameTextField) {
            self.parent = parent
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didCancel = false
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didCancel = true
                control.stringValue = parent.filename
                parent.onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? FilenameNSTextField else { return }
            tf.refusesFirstResponder = true
            if didCancel {
                didCancel = false
                tf.stringValue = parent.filename
                return
            }
            let newText = tf.stringValue
            parent.onCommit(newText)
            DispatchQueue.main.async { [weak tf, weak self] in
                guard let tf, let self else { return }
                tf.stringValue = self.parent.filename
            }
        }
    }
}
