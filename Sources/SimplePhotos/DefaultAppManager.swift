import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
public enum DefaultAppManager {
    public static let simplePhotosBundleID = "com.simplephotos.mac"
    public static let previewBundleID = "com.apple.Preview"

    /// Collects all UTTypes corresponding to supported still and animated image formats.
    public static func allSupportedImageUTTypes() -> [UTType] {
        var seen = Set<String>()
        var result: [UTType] = []

        func add(_ type: UTType?) {
            guard let type else { return }
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) {
                return
            }
            if seen.insert(type.identifier).inserted {
                result.append(type)
            }
        }

        let baseTypes: [UTType] = [
            .image, .jpeg, .png, .gif, .webP, .heic, .heif,
            .tiff, .bmp, .ico, .icns, .svg, .rawImage
        ]
        for t in baseTypes {
            add(t)
        }

        for ext in PhotoViewerViewModel.supportedExtensions.sorted() {
            add(UTType(filenameExtension: ext))
        }

        return result
    }

    public static func simplePhotosAppURL() -> URL? {
        let mainURL = Bundle.main.bundleURL
        if mainURL.pathExtension == "app" {
            return mainURL
        }
        let appInApplications = URL(fileURLWithPath: "/Applications/SimplePhotos.app")
        if FileManager.default.fileExists(atPath: appInApplications.path) {
            return appInApplications
        }
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: simplePhotosBundleID) {
            return found
        }
        return nil
    }

    public static func previewAppURL() -> URL? {
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previewBundleID) {
            return found
        }
        let systemPreview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        if FileManager.default.fileExists(atPath: systemPreview.path) {
            return systemPreview
        }
        return nil
    }

    /// Returns true if Simple Photos is currently registered as the default handler for common image types (JPEG & PNG).
    public static func isSimplePhotosCurrentlyDefault() -> Bool {
        let probeTypes: [UTType] = [.jpeg, .png]
        var matchCount = 0
        for t in probeTypes {
            if let appURL = NSWorkspace.shared.urlForApplication(toOpen: t) {
                let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased() ?? ""
                let name = appURL.lastPathComponent.lowercased()
                if bundleID == simplePhotosBundleID || name.contains("simplephotos") {
                    matchCount += 1
                }
            }
        }
        return matchCount == probeTypes.count
    }

    /// Sets Simple Photos as the default viewer for all supported image UTTypes.
    public static func setSimplePhotosAsDefault() async -> Bool {
        let types = allSupportedImageUTTypes()

        // 1. Set via LaunchServices role handler for all image content types
        for utType in types {
            let cfType = utType.identifier as CFString
            LSSetDefaultRoleHandlerForContentType(cfType, .viewer, simplePhotosBundleID as CFString)
            LSSetDefaultRoleHandlerForContentType(cfType, .all, simplePhotosBundleID as CFString)
        }

        // 2. Also apply via modern NSWorkspace API if bundle URL is available
        if let appURL = simplePhotosAppURL() {
            for utType in types {
                try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: utType)
            }
        }

        return isSimplePhotosCurrentlyDefault()
    }

    /// Restores macOS Preview (com.apple.Preview) as the default viewer for all supported image UTTypes.
    public static func restorePreviewAsDefault() async -> Bool {
        let types = allSupportedImageUTTypes()

        // 1. Set via LaunchServices role handler back to com.apple.Preview
        for utType in types {
            let cfType = utType.identifier as CFString
            LSSetDefaultRoleHandlerForContentType(cfType, .viewer, previewBundleID as CFString)
            LSSetDefaultRoleHandlerForContentType(cfType, .all, previewBundleID as CFString)
        }

        // 2. Also apply via modern NSWorkspace API
        if let previewURL = previewAppURL() {
            for utType in types {
                try? await NSWorkspace.shared.setDefaultApplication(at: previewURL, toOpen: utType)
            }
        }

        return !isSimplePhotosCurrentlyDefault()
    }
}
