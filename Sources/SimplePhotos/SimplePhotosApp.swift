import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    public let viewModel = PhotoViewerViewModel()
    public private(set) var mainWindow: NSWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMainMenu()
        ensureMainWindow()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        ensureMainWindow()
        installKeyboardShortcutsMonitor()
        handleCommandLineArguments()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        ensureMainWindow()
        viewModel.open(urls: urls)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureMainWindow()
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @discardableResult
    public func ensureMainWindow() -> NSWindow {
        if let existing = mainWindow {
            return existing
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Simple Photos"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)
        window.isOpaque = true
        window.hasShadow = true
        window.toolbar = nil
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .disallowed
        window.delegate = self

        let rootView = ContentView(viewModel: viewModel)
            .preferredColorScheme(.dark)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1080, height: 740)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        window.center()
        window.setFrameAutosaveName("SimplePhotosSingleWindow")

        self.mainWindow = window
        return window
    }

    // MARK: - NSWindowDelegate (Fullscreen State)

    public func windowWillEnterFullScreen(_ notification: Notification) {
        viewModel.showMetadataPopover = false
        viewModel.statusToast = nil
        viewModel.isFullScreen = true
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        viewModel.isFullScreen = true
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        viewModel.isFullScreen = false
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        viewModel.isFullScreen = false
    }

    // MARK: - CLI Arguments

    private func handleCommandLineArguments() {
        let args = Array(CommandLine.arguments.dropFirst())
        var urlsToOpen: [URL] = []

        for arg in args {
            if arg.hasPrefix("-") { continue }
            let expanded = (arg as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                urlsToOpen.append(url)
            }
        }

        if !urlsToOpen.isEmpty {
            viewModel.open(urls: urlsToOpen)
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Simple Photos", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefAutoBg = NSMenuItem(title: "Automatic Background Color", action: #selector(menuToggleAutoBackground), keyEquivalent: ",")
        prefAutoBg.target = self
        appMenu.addItem(prefAutoBg)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Simple Photos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Simple Photos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: "Open Image or Folder…", action: #selector(menuOpenFile), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        let sampleItem = NSMenuItem(title: "Load Sample Gallery", action: #selector(menuLoadSample), keyEquivalent: "")
        sampleItem.target = self
        fileMenu.addItem(sampleItem)

        fileMenu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder), keyEquivalent: "R")
        revealItem.keyEquivalentModifierMask = [.command, .shift]
        revealItem.target = self
        fileMenu.addItem(revealItem)

        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(menuMoveToTrash), keyEquivalent: "\u{08}")
        trashItem.keyEquivalentModifierMask = [.command]
        trashItem.target = self
        fileMenu.addItem(trashItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 3. Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        let copyImgItem = NSMenuItem(title: "Copy Image", action: #selector(menuCopyImage), keyEquivalent: "c")
        copyImgItem.target = self
        editMenu.addItem(copyImgItem)

        let copyPathItem = NSMenuItem(title: "Copy File Path", action: #selector(menuCopyPath), keyEquivalent: "C")
        copyPathItem.keyEquivalentModifierMask = [.command, .shift]
        copyPathItem.target = self
        editMenu.addItem(copyPathItem)

        // 4. Navigate Menu
        let navMenuItem = NSMenuItem()
        mainMenu.addItem(navMenuItem)
        let navMenu = NSMenu(title: "Navigate")
        navMenuItem.submenu = navMenu

        let prevItem = NSMenuItem(title: "Previous Photo", action: #selector(menuPrevPhoto), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.command]
        prevItem.target = self
        navMenu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "Next Photo", action: #selector(menuNextPhoto), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.command]
        nextItem.target = self
        navMenu.addItem(nextItem)

        navMenu.addItem(.separator())

        let slideItem = NSMenuItem(title: "Toggle Slideshow", action: #selector(menuToggleSlideshow), keyEquivalent: "")
        slideItem.target = self
        navMenu.addItem(slideItem)

        // 5. Image / View Menu
        let imgMenuItem = NSMenuItem()
        mainMenu.addItem(imgMenuItem)
        let imgMenu = NSMenu(title: "Image")
        imgMenuItem.submenu = imgMenu

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(menuZoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        imgMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(menuZoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        imgMenu.addItem(zoomOutItem)

        let fitItem = NSMenuItem(title: "Fit to Window", action: #selector(menuZoomFit), keyEquivalent: "0")
        fitItem.target = self
        imgMenu.addItem(fitItem)

        let actualItem = NSMenuItem(title: "Actual Size (1:1)", action: #selector(menuZoomActual), keyEquivalent: "1")
        actualItem.target = self
        imgMenu.addItem(actualItem)

        imgMenu.addItem(.separator())

        let rotLeftItem = NSMenuItem(title: "Rotate Left", action: #selector(menuRotateLeft), keyEquivalent: "l")
        rotLeftItem.target = self
        imgMenu.addItem(rotLeftItem)

        let rotRightItem = NSMenuItem(title: "Rotate Right", action: #selector(menuRotateRight), keyEquivalent: "r")
        rotRightItem.target = self
        imgMenu.addItem(rotRightItem)

        let flipItem = NSMenuItem(title: "Flip Horizontally", action: #selector(menuFlipHorizontal), keyEquivalent: "")
        flipItem.target = self
        imgMenu.addItem(flipItem)

        imgMenu.addItem(.separator())

        let autoBgItem = NSMenuItem(title: "Automatic Background Color", action: #selector(menuToggleAutoBackground), keyEquivalent: "b")
        autoBgItem.target = self
        imgMenu.addItem(autoBgItem)

        imgMenu.addItem(.separator())

        let fullScreenItem = NSMenuItem(title: "Toggle Fullscreen", action: #selector(menuToggleFullscreen), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        fullScreenItem.target = self
        imgMenu.addItem(fullScreenItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuOpenFile() { viewModel.presentOpenPanel() }
    @objc private func menuLoadSample() { SampleGalleryGenerator.openDemoGallery(in: viewModel) }
    @objc private func menuRevealInFinder() { viewModel.revealInFinder() }
    @objc private func menuMoveToTrash() { viewModel.moveCurrentImageToTrash() }
    @objc private func menuCopyImage() { viewModel.copyImageToClipboard() }
    @objc private func menuCopyPath() { viewModel.copyFilePathToClipboard() }
    @objc private func menuPrevPhoto() { viewModel.previousImage() }
    @objc private func menuNextPhoto() { viewModel.nextImage() }
    @objc private func menuToggleSlideshow() { viewModel.toggleSlideshow() }
    @objc private func menuZoomIn() { viewModel.zoomIn() }
    @objc private func menuZoomOut() { viewModel.zoomOut() }
    @objc private func menuZoomFit() { viewModel.resetZoomToFit() }
    @objc private func menuZoomActual() { viewModel.toggleActualSizeOrFit() }
    @objc private func menuRotateLeft() { viewModel.rotateLeft() }
    @objc private func menuRotateRight() { viewModel.rotateRight() }
    @objc private func menuFlipHorizontal() { viewModel.toggleFlipHorizontal() }
    @objc private func menuToggleAutoBackground() { viewModel.toggleAutoBackgroundColor() }
    @objc private func menuToggleFullscreen() { viewModel.toggleFullScreen() }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(menuToggleAutoBackground) {
            menuItem.state = viewModel.autoBackgroundColorEnabled ? .on : .off
            return true
        }
        return true
    }

    // MARK: - Keyboard Monitor

    private func installKeyboardShortcutsMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyDown(event) {
                return nil
            }
            return event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if self.handleExtremeEdgeMouseDown(event) {
                return nil
            }
            return event
        }
    }

    private func handleExtremeEdgeMouseDown(_ event: NSEvent) -> Bool {
        guard viewModel.hasImages,
              viewModel.canNavigate,
              viewModel.zoomScale <= 1.01,
              !viewModel.showMetadataPopover,
              let window = mainWindow else {
            return false
        }
        if NSApp.keyWindow is NSPanel {
            return false
        }

        let winSize = window.frame.size
        let loc: NSPoint
        if let evWin = event.window, evWin === window {
            loc = event.locationInWindow
        } else if viewModel.isFullScreen {
            loc = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        } else {
            return false
        }

        // In Fullscreen, handle the entire left/right click zone directly here (including 0px / maxX screen edges).
        // In Windowed mode, intercept clicks near the left/right window border (<= 16px from edge)
        // where NSWindow's resize frame would otherwise swallow the click.
        let isNearWindowEdge = loc.x <= 16 || loc.x >= (winSize.width - 16)
        guard viewModel.isFullScreen || isNearWindowEdge else {
            return false
        }

        let zone = InteractiveCanvasNSView.navigationZone(
            for: loc,
            in: winSize,
            isFullScreen: viewModel.isFullScreen
        )
        switch zone {
        case .leftPrevious:
            viewModel.previousImage()
            return true
        case .rightNext:
            viewModel.nextImage()
            return true
        case .center:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }
        if NSApp.keyWindow is NSPanel {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift)
        let isNoModifier = flags.subtracting([.numericPad, .function]).isEmpty

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isCmd {
            switch chars {
            case "o":
                viewModel.presentOpenPanel()
                return true
            case "c":
                if viewModel.hasImages {
                    if isShift {
                        viewModel.copyFilePathToClipboard()
                    } else {
                        viewModel.copyImageToClipboard()
                    }
                    return true
                }
            case "l":
                if viewModel.hasImages {
                    viewModel.rotateLeft()
                    return true
                }
            case "r":
                if viewModel.hasImages {
                    if isShift {
                        viewModel.revealInFinder()
                    } else {
                        viewModel.rotateRight()
                    }
                    return true
                }
            case "+", "=":
                if viewModel.hasImages {
                    viewModel.zoomIn()
                    return true
                }
            case "-":
                if viewModel.hasImages {
                    viewModel.zoomOut()
                    return true
                }
            case "0":
                if viewModel.hasImages {
                    viewModel.resetZoomToFit()
                    return true
                }
            case "b":
                viewModel.toggleAutoBackgroundColor()
                return true
            case "1":
                if viewModel.hasImages {
                    viewModel.toggleActualSizeOrFit()
                    return true
                }
            default:
                break
            }

            if event.keyCode == 51 && viewModel.hasImages {
                viewModel.moveCurrentImageToTrash()
                return true
            }

            return false
        }

        guard viewModel.hasImages else {
            return false
        }

        switch event.keyCode {
        case 123, 126: // Left Arrow, Up Arrow
            if isNoModifier {
                viewModel.previousImage()
                return true
            }
        case 124, 125: // Right Arrow, Down Arrow
            if isNoModifier {
                viewModel.nextImage()
                return true
            }
        case 115: // Home
            viewModel.firstImage()
            return true
        case 119: // End
            viewModel.lastImage()
            return true
        case 49: // Space
            if isNoModifier {
                viewModel.toggleSlideshow()
                return true
            }
        case 51, 117: // Delete / Backspace / Forward Delete
            if isNoModifier {
                viewModel.moveCurrentImageToTrash()
                return true
            }
        case 53: // Escape
            if viewModel.isSlideshowActive {
                viewModel.stopSlideshow()
                return true
            }
            if viewModel.showMetadataPopover {
                viewModel.showMetadataPopover = false
                return true
            }
            if abs(viewModel.zoomScale - 1.0) > 0.02 {
                viewModel.resetZoomToFit()
                return true
            }
            if let win = NSApp.keyWindow, win.styleMask.contains(.fullScreen) {
                win.toggleFullScreen(nil)
                return true
            }
            return false
        default:
            break
        }

        if isNoModifier || flags == [.shift] {
            switch chars {
            case "+", "=":
                viewModel.zoomIn()
                return true
            case "-", "_":
                viewModel.zoomOut()
                return true
            case "0":
                viewModel.resetZoomToFit()
                return true
            case "1":
                viewModel.toggleActualSizeOrFit()
                return true
            case "[":
                viewModel.rotateLeft()
                return true
            case "]":
                viewModel.rotateRight()
                return true
            case "a", "h":
                viewModel.previousImage()
                return true
            case "d", "l":
                viewModel.nextImage()
                return true
            case "r":
                if isShift {
                    viewModel.rotateLeft()
                } else {
                    viewModel.rotateRight()
                }
                return true
            case "m":
                viewModel.toggleFlipHorizontal()
                return true
            case "b":
                viewModel.toggleAutoBackgroundColor()
                return true
            case "g":
                viewModel.checkerboardBackground.toggle()
                return true
            case "i":
                viewModel.showMetadataPopover.toggle()
                return true
            case "t":
                viewModel.isAlwaysOnTop.toggle()
                return true
            case "f":
                viewModel.toggleFullScreen()
                return true
            default:
                break
            }
        }

        return false
    }
}

@main
public enum SimplePhotosMain {
    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
