import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a runner screenshot for the model request.
///
/// The runner returns a full-resolution PNG (e.g. 1206x2622 on a 3x device, ~300 KB
/// base64 per step). The model only needs legible text and layout: tap points are
/// 0...1 ratios of the whole screenshot and OCR runs on the original PNG, so nothing
/// depends on the encoded pixel size. Downscale the long edge to `maxLongEdgePixels`
/// (about 0.5x of a 3x phone, i.e. 1.5 px per point) and store JPEG.
enum IOSPhoneScreenshotEncoder {
    static let maxLongEdgePixels = 1_280
    static let jpegQuality = 0.65

    struct Encoded: Equatable {
        let data: Data
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int

        var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    }

    /// Returns nil when the input cannot be decoded or re-encoded; callers keep the original.
    static func encodeForModel(
        _ imageData: Data,
        maxLongEdge: Int = maxLongEdgePixels,
        quality: Double = jpegQuality
    ) -> Encoded? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let target = max(1, min(maxLongEdge, max(width, height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return Encoded(data: output as Data, mimeType: "image/jpeg", pixelWidth: image.width, pixelHeight: image.height)
    }
}
