import AmberPhoneControl
import CoreGraphics
import Foundation
import ImageIO

/// One full-screen image. Padding is described in the decision state so screen bounds
/// still map to the original observation rather than to the padded canvas.
struct IOSJevPhoneImage: Sendable {
    let asset: IOSJevImageAsset
    let contentBounds: [Double]

    enum Error: Swift.Error {
        case invalidScreenshot
        case encodingFailed
    }

    static func prepare(from screenshot: PhoneScreenshot) async throws -> Self {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try encode(screenshot)
        }
        return try await withTaskCancellationHandler {
            let image = try await work.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            work.cancel()
        }
    }

    private static func encode(_ screenshot: PhoneScreenshot) throws -> Self {
        guard screenshot.width.isFinite, screenshot.height.isFinite,
              screenshot.width > 0, screenshot.height > 0,
              let source = CGImageSourceCreateWithData(screenshot.data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_568,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw Error.invalidScreenshot }
        let width = Double(image.width)
        let height = Double(image.height)
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw Error.invalidScreenshot }
        let rotated = (5...8).contains(orientation)
        let sourceWidth = rotated ? pixelHeight.doubleValue : pixelWidth.doubleValue
        let sourceHeight = rotated ? pixelWidth.doubleValue : pixelHeight.doubleValue
        let expected = sourceWidth * screenshot.height
        let actual = sourceHeight * screenshot.width
        guard abs(expected - actual) <= max(expected, actual) * 0.005 else {
            throw Error.invalidScreenshot
        }
        let scale = min(1_568 / max(width, height), max(1, 280 / min(width, height)))
        let contentWidth = max(1, min(1_568, Int((width * scale).rounded())))
        let contentHeight = max(1, min(1_568, Int((height * scale).rounded())))
        let canvasWidth = max(280, contentWidth)
        let canvasHeight = max(280, contentHeight)
        let x = (canvasWidth - contentWidth) / 2
        let y = (canvasHeight - contentHeight) / 2
        guard let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Error.encodingFailed
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: y, width: contentWidth, height: contentHeight))
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw Error.encodingFailed
        }
        CGImageDestinationAddImage(destination, output, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Error.encodingFailed }
        // Core Graphics draws from the bottom left; decision state uses image top left.
        return Self(asset: .init(data: data as Data, format: "jpg"), contentBounds: [
            Double(x) / Double(canvasWidth),
            Double(canvasHeight - y - contentHeight) / Double(canvasHeight),
            Double(x + contentWidth) / Double(canvasWidth),
            Double(canvasHeight - y) / Double(canvasHeight),
        ])
    }
}
