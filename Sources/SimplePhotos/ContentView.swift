import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var viewModel: PhotoViewerViewModel

    @State private var isHUDVisible: Bool = false
    @State private var isHoveringHUDControl: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var hideTimerWorkItem: DispatchWorkItem?

    public init(viewModel: PhotoViewerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Background Canvas (Pure black in fullscreen, near-black in windowed, or optional checkerboard)
            backgroundLayer
                .ignoresSafeArea()

            if viewModel.hasImages {
                InteractiveImageCanvas(
                    viewModel: viewModel,
                    onUserActivity: {
                        registerUserActivity()
                    }
                )
                .ignoresSafeArea()
            } else {
                emptyWelcomeState
            }

            // Drop highlight border
            if isDropTargeted && !viewModel.isFullScreen {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Floating Status Toast (Windowed mode only — never in Fullscreen)
            if !viewModel.isFullScreen, let toast = viewModel.statusToast {
                VStack {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .padding(.top, 48)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(20)
            }

            // Ultra-Minimal Floating HUD (Windowed mode ONLY — completely hidden in Fullscreen!)
            if viewModel.hasImages && !viewModel.isFullScreen {
                windowedFloatingHUD
                    .opacity(effectiveHUDVisibility ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.18), value: effectiveHUDVisibility)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onHover { hoveringWindow in
            if hoveringWindow {
                registerUserActivity()
            } else if !viewModel.showMetadataPopover {
                setHUDVisible(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: viewModel.showMetadataPopover) { _, isShowing in
            if isShowing {
                setHUDVisible(true)
            } else {
                scheduleHUDHide()
            }
        }
        .onChange(of: viewModel.isFullScreen) { _, fullScreen in
            if fullScreen {
                hideTimerWorkItem?.cancel()
                isHoveringHUDControl = false
                isHUDVisible = false
            }
        }
        .onAppear {
            updateWindowTrafficLights(visible: !viewModel.hasImages)
        }
    }

    private var effectiveHUDVisibility: Bool {
        guard !viewModel.isFullScreen else { return false }
        return isHUDVisible || isHoveringHUDControl || viewModel.showMetadataPopover || !viewModel.hasImages
    }

    // MARK: - Background Layer

    @ViewBuilder
    private var backgroundLayer: some View {
        if viewModel.checkerboardBackground && viewModel.hasImages && !viewModel.isFullScreen {
            CheckerboardBackgroundView()
        } else if viewModel.autoBackgroundColorEnabled && viewModel.hasImages,
                  let bgColor = viewModel.detectedBackgroundColor {
            Color(nsColor: bgColor)
        } else if viewModel.isFullScreen {
            Color.black
        } else {
            Color(red: 0.04, green: 0.04, blue: 0.045)
        }
    }

    // MARK: - Clean Windowed Floating HUD (Zero clutter, zero duplicate controls)

    private var windowedFloatingHUD: some View {
        VStack {
            // Subtle Top Pill: Filename & Index only
            HStack {
                Spacer(minLength: 72)
                topCompactInfoPill
                    .allowsHitTesting(effectiveHUDVisibility)
                Spacer(minLength: 72)
            }
            .padding(.top, 10)

            Spacer()

            // Single Compact Bottom Pill
            bottomCompactDock
                .allowsHitTesting(effectiveHUDVisibility)
                .padding(.bottom, 16)
        }
    }

    private var topCompactInfoPill: some View {
        HStack(spacing: 7) {
            Text(viewModel.metadata.filename)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)

            Text("•")
                .foregroundStyle(.white.opacity(0.35))

            Text(viewModel.positionText)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .onHover { hovering in
            isHoveringHUDControl = hovering
        }
    }

    private var bottomCompactDock: some View {
        HStack(spacing: 4) {
            hudIconButton(
                systemName: "chevron.left",
                isDisabled: !viewModel.canNavigate,
                help: "Previous Photo (←)"
            ) {
                viewModel.previousImage()
            }

            hudIconButton(
                systemName: "chevron.right",
                isDisabled: !viewModel.canNavigate,
                help: "Next Photo (→)"
            ) {
                viewModel.nextImage()
            }

            hudDivider

            hudIconButton(
                systemName: "rotate.left",
                help: "Rotate Left ([)"
            ) {
                viewModel.rotateLeft()
            }

            hudIconButton(
                systemName: "rotate.right",
                help: "Rotate Right (])"
            ) {
                viewModel.rotateRight()
            }

            hudDivider

            hudIconButton(
                systemName: viewModel.autoBackgroundColorEnabled ? "paintbrush.fill" : "paintbrush",
                isActive: viewModel.autoBackgroundColorEnabled,
                help: "Toggle Automatic Background Color (B)"
            ) {
                viewModel.toggleAutoBackgroundColor()
            }

            hudIconButton(
                systemName: "info.circle",
                isActive: viewModel.showMetadataPopover,
                help: "Photo Info & Options (I)"
            ) {
                viewModel.showMetadataPopover.toggle()
            }
            .popover(isPresented: $viewModel.showMetadataPopover, arrowEdge: .top) {
                metadataPopoverView
            }

            hudIconButton(
                systemName: "magnifyingglass",
                isActive: viewModel.isSearchingYandex,
                isDisabled: viewModel.isSearchingYandex,
                help: "Search Image in Yandex (Y)"
            ) {
                viewModel.searchCurrentImageInYandex()
            }

            hudIconButton(
                systemName: "folder",
                help: "Reveal in Finder (⇧⌘R)"
            ) {
                viewModel.revealInFinder()
            }

            hudIconButton(
                systemName: "trash",
                isDestructive: true,
                help: "Move to Trash (Delete)"
            ) {
                viewModel.moveCurrentImageToTrash()
            }

            hudDivider

            hudIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                help: "Fullscreen (Double-Click or F)"
            ) {
                viewModel.toggleFullScreen()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .onHover { hovering in
            isHoveringHUDControl = hovering
        }
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func hudIconButton(
        systemName: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        isDestructive: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        HUDIconButton(
            systemName: systemName,
            isActive: isActive,
            isDisabled: isDisabled,
            isDestructive: isDestructive,
            help: help,
            action: action
        )
    }

    // MARK: - Metadata Popover

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
        .frame(width: 290)
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
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.28), Color.indigo.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }

            VStack(spacing: 8) {
                Text("Simple Photos")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Drop an image or folder here, or open any photo.\nSibling photos in the same folder load automatically for ← / → browsing.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.presentOpenPanel()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus")
                        Text("Open Image or Folder…")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    SampleGalleryGenerator.openDemoGallery(in: viewModel)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles.rectangle.stack")
                        Text("Try Sample Photos")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isUpdatingDefaultViewer)
            }

            HStack(spacing: 14) {
                shortcutBadge("← / →", "Prev / Next")
                shortcutBadge("Double-Click", "Fullscreen")
                shortcutBadge("Scroll / Pinch", "Zoom")
                shortcutBadge("[ / ]", "Rotate")
                shortcutBadge("⌫", "Trash")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func shortcutBadge(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Hover & Traffic Light Visibility

    private func registerUserActivity() {
        guard !viewModel.isFullScreen else { return }
        setHUDVisible(true)
        scheduleHUDHide()
    }

    private func scheduleHUDHide() {
        hideTimerWorkItem?.cancel()
        guard viewModel.hasImages && !viewModel.isFullScreen else { return }

        let item = DispatchWorkItem {
            if !isHoveringHUDControl && !viewModel.showMetadataPopover {
                setHUDVisible(false)
            }
        }
        hideTimerWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func setHUDVisible(_ visible: Bool) {
        if isHUDVisible != visible {
            isHUDVisible = visible
        }
        updateWindowTrafficLights(visible: (visible && !viewModel.isFullScreen) || !viewModel.hasImages)
    }

    private func updateWindowTrafficLights(visible: Bool) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            return
        }
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0
        for btnType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let btn = window.standardWindowButton(btnType) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    btn.animator().alphaValue = targetAlpha
                }
            }
        }
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

// MARK: - Helper Subviews

private struct HUDIconButton: View {
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 28, height: 26)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return .white.opacity(0.28)
        }
        if isDestructive && isHovered {
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
        if isActive {
            return Color.accentColor
        }
        return .white.opacity(isHovered ? 1.0 : 0.85)
    }

    private var backgroundColor: Color {
        if isDisabled {
            return .clear
        }
        if isActive {
            return Color.white.opacity(0.16)
        }
        if isHovered {
            return isDestructive ? Color.red.opacity(0.18) : Color.white.opacity(0.12)
        }
        return .clear
    }
}

private struct CheckerboardBackgroundView: View {
    var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 16
            let cols = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            let dark = Color(white: 0.12)
            let light = Color(white: 0.18)

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark))

            for r in 0..<rows {
                for c in 0..<cols where (r + c).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(c) * tileSize,
                        y: CGFloat(r) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    context.fill(Path(rect), with: .color(light))
                }
            }
        }
    }
}
