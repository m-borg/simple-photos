import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Vision

public enum BackgroundRemovalError: LocalizedError {
    case noForegroundDetected
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noForegroundDetected:
            return "No foreground subject detected"
        case .renderFailed:
            return "Could not render background-removed image"
        }
    }
}

public enum BackgroundRemover {
    /// Uses macOS's native Vision foreground instance mask (the engine behind Finder Quick Actions -> Remove Background)
    /// to lift the foreground subject and return a transparent-background CGImage.
    public static func removeBackground(from cgImage: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw BackgroundRemovalError.noForegroundDetected
        }

        let maskedPixelBuffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )

        let ciImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCGImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw BackgroundRemovalError.renderFailed
        }
        return outputCGImage
    }
}
