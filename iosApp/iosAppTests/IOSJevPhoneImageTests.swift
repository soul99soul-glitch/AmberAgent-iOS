import AmberPhoneControl
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import iosApp

nonisolated func jevPhonePNG(width: Int = 402, height: Int = 874, orientation: Int = 1) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

final class IOSJevPhoneImageTests: XCTestCase {
    func testPhoneImageUsesBoundedUprightBaselineJPEG() async throws {
        let screenshot = PhoneScreenshot(data: try jevPhonePNG(width: 1_206, height: 2_622),
                                         observationID: "o1", width: 402, height: 874)
        let image = try await IOSJevPhoneImage.prepare(from: screenshot)
        XCTAssertEqual(image.asset.format, "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.asset.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
        XCTAssertEqual(max(width, height), 1_568)
        XCTAssertGreaterThanOrEqual(min(width, height), 280)
        let orientation = (properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
        XCTAssertEqual(orientation, 1)
        let jfif = properties[kCGImagePropertyJFIFDictionary as String] as? [String: Any]
        XCTAssertNotEqual(jfif?[kCGImagePropertyJFIFIsProgressive as String] as? Bool, true)
        XCTAssertEqual(image.contentBounds, [0, 0, 1, 1])
    }

    func testThinScreenshotPadsWithoutCroppingAndDescribesContentBounds() async throws {
        let screenshot = PhoneScreenshot(data: try jevPhonePNG(width: 200, height: 4_000),
                                         observationID: "thin", width: 200, height: 4_000)
        let image = try await IOSJevPhoneImage.prepare(from: screenshot)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.asset.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 280)
        XCTAssertEqual(decoded.height, 1_568)
        XCTAssertGreaterThan(image.contentBounds[0], 0)
        XCTAssertEqual(image.contentBounds[1], 0)
        XCTAssertLessThan(image.contentBounds[2], 1)
        XCTAssertEqual(image.contentBounds[3], 1)
        XCTAssertEqual(image.contentBounds[2] - image.contentBounds[0], 78.0 / 280, accuracy: 0.01)
    }

    func testSmallPhoneImageMeetsMinimumSize() async throws {
        let image = try await IOSJevPhoneImage.prepare(from: .init(
            data: try jevPhonePNG(width: 80, height: 160), observationID: "small", width: 400, height: 800))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.asset.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 280)
        XCTAssertEqual(decoded.height, 560)
        XCTAssertEqual(image.contentBounds, [0, 0, 1, 1])
    }

    func testRotatedPNGIsNormalizedBeforeEncoding() async throws {
        let image = try await IOSJevPhoneImage.prepare(from: .init(
            data: try jevPhonePNG(width: 800, height: 400, orientation: 6),
            observationID: "rotated", width: 400, height: 800))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.asset.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThan(decoded.width, decoded.height)
        XCTAssertEqual(image.contentBounds, [0, 0, 1, 1])
    }

    func testAsymmetricCornerColorsStayUprightAndHonorEXIFRotation() async throws {
        // Raw scanlines establish top-left red, top-right green, bottom-left blue,
        // bottom-right yellow independently of a drawing context's coordinate system.
        let red = [UInt8(240), 20, 20]
        let green = [UInt8(20), 230, 20]
        let blue = [UInt8(20), 20, 240]
        let yellow = [UInt8(240), 230, 20]
        let width = 480
        let height = 320
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = y < height / 2 ? (x < width / 2 ? red : green) : (x < width / 2 ? blue : yellow)
                pixels.append(contentsOf: color)
                pixels.append(255)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let rawImage = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                           bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                                           bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
                                           provider: provider, decode: nil, shouldInterpolate: false,
                                           intent: .defaultIntent))
        // EXIF 6 is a clockwise quarter-turn: blue/red/yellow/green in display order.
        for (orientation, expectedCorners) in [(1, [red, green, blue, yellow]), (6, [blue, red, yellow, green])] {
            let png = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, rawImage, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let screenshot = PhoneScreenshot(data: png as Data, observationID: "corners-\(orientation)",
                                             width: orientation == 1 ? 480 : 320,
                                             height: orientation == 1 ? 320 : 480)
            let encoded = try await IOSJevPhoneImage.prepare(from: screenshot)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.asset.data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let samplePoints = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
            for (index, point) in samplePoints.enumerated() {
                // Crop first: rendering a single pixel cannot conceal an axis flip.
                let pixel = try XCTUnwrap(image.cropping(to: CGRect(
                    x: Int(Double(image.width) * point.0), y: Int(Double(image.height) * point.1),
                    width: 1, height: 1)))
                var sample = [UInt8](repeating: 0, count: 4)
                try sample.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                for channel in 0..<3 {
                    XCTAssertEqual(Double(sample[channel]), Double(expectedCorners[index][channel]), accuracy: 18,
                                   "EXIF \(orientation), corner \(index), RGB channel \(channel)")
                }
            }
        }
    }

    func testInvalidDataOrMismatchedGeometryIsRejected() async throws {
        let png = try jevPhonePNG(width: 400, height: 800)
        for screenshot in [
            PhoneScreenshot(data: Data("bad image".utf8), observationID: "bad", width: 400, height: 800),
            PhoneScreenshot(data: png, observationID: "rotated", width: 800, height: 400),
            PhoneScreenshot(data: png, observationID: "invalid", width: .infinity, height: 800),
        ] {
            do {
                _ = try await IOSJevPhoneImage.prepare(from: screenshot)
                XCTFail("Invalid screenshot should not be sent")
            } catch IOSJevPhoneImage.Error.invalidScreenshot {
                // Expected input validation failure.
            }
        }
    }
}
