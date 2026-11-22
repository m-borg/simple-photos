import AppKit
import CoreGraphics
import Foundation

public enum YandexImageSearchError: LocalizedError {
    case encodingFailed
    case uploadFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode image for Yandex search"
        case .uploadFailed(let msg):
            return "Yandex upload failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from Yandex Image Search"
        }
    }
}

public enum YandexImageSearch {
    private struct UploadResponse: Decodable {
        let url: String?
        let cbir_id: String?
    }

    /// Downscales the CGImage to max 512px and encodes as JPEG (matching the Chrome extension mpcooeefegelfehalmefdeojlkinjjho).
    public static func prepareJPEGData(from cgImage: CGImage, maxDimension: CGFloat = 512.0) -> Data? {
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        guard origW > 0, origH > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(origW, origH))
        let targetW = max(1, Int(round(origW * scale)))
        let targetH = max(1, Int(round(origH * scale)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = nsCtx
        let cg = nsCtx.cgContext

        let rect = CGRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH))
        // Fill white behind transparent images so JPEG conversion doesn't turn alpha into solid black
        cg.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        cg.fill(rect)
        cg.interpolationQuality = .high
        cg.draw(cgImage, in: rect)

        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    /// Replicates JavaScript's `encodeURIComponent(url)`
    public static func encodeURIComponent(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// Builds the Yandex Image Search result URL from the uploaded image URL.
    public static func buildSearchURL(uploadedImageURL: String, zone: String = "com") -> URL? {
        let encoded = encodeURIComponent(uploadedImageURL)
        return URL(string: "https://yandex.\(zone)/images/search?rpt=imageview&url=\(encoded)")
    }

    /// Uploads the image to `https://yandex.ru/images-apphost/image-download` and returns the Yandex Search URL.
    public static func searchImage(cgImage: CGImage) async throws -> URL {
        guard let jpegData = prepareJPEGData(from: cgImage) else {
            throw YandexImageSearchError.encodingFailed
        }

        let endpoint = URL(string: "https://yandex.ru/images-apphost/image-download")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = jpegData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YandexImageSearchError.uploadFailed("HTTP \(code)")
        }

        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        if let remoteImageURL = decoded.url,
           let searchURL = buildSearchURL(uploadedImageURL: remoteImageURL, zone: "com") {
            return searchURL
        }
        if let cbirId = decoded.cbir_id,
           let fallbackURL = URL(string: "https://yandex.com/images/search?rpt=imageview&cbir_id=\(encodeURIComponent(cbirId))") {
            return fallbackURL
        }

        throw YandexImageSearchError.invalidResponse
    }
}
