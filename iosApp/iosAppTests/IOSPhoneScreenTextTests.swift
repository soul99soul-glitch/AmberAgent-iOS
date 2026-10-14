import AmberPhoneControl
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneScreenTextTests: XCTestCase {
    func testRealVisionRecognizesChineseAndEnglishAtScreenshotCoordinates() async throws {
        let lines = [
            FixtureLine(text: "自动化点击", x: 90, top: 100),
            FixtureLine(text: "畫面文字識別", x: 110, top: 600),
            FixtureLine(text: "Amber Search 42", x: 180, top: 1_050),
        ]
        let screenshot = try makeScreenshot(lines: lines, observationID: "screen-text-fixture")
        let result = try await IOSPhoneScreenText.recognize(screenshot)

        XCTAssertEqual(result.observationID, "screen-text-fixture")
        XCTAssertEqual(result.source, "ocr")
        XCTAssertEqual(result.coordinateSpace, "screenshot_normalized_top_left")
        XCTAssertNil(result.emptyReason)
        XCTAssertEqual(result.coverageAdvice, .textOnly)
        XCTAssertGreaterThan(result.ocrMs, 0)

        for line in lines {
            let item = try XCTUnwrap(result.items.first {
                $0.text.replacingOccurrences(of: " ", with: "") == line.text.replacingOccurrences(of: " ", with: "")
            }, "Missing actual Vision text: \(line.text); got \(result.items.map(\.text))")
            XCTAssertTrue(item.confidence.isFinite)
            XCTAssertGreaterThanOrEqual(item.confidence, 0)
            XCTAssertLessThanOrEqual(item.confidence, 1)
            XCTAssertGreaterThan(item.bbox.width, 0)
            XCTAssertGreaterThan(item.bbox.height, 0)
            XCTAssertEqual(item.center.x, item.bbox.x + item.bbox.width / 2, accuracy: 0.000_001)
            XCTAssertEqual(item.center.y, item.bbox.y + item.bbox.height / 2, accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(item.bbox.x, 0)
            XCTAssertGreaterThanOrEqual(item.bbox.y, 0)
            XCTAssertLessThanOrEqual(item.bbox.x + item.bbox.width, 1)
            XCTAssertLessThanOrEqual(item.bbox.y + item.bbox.height, 1)
            // The fixture has known top-left text positions, independently of Vision's bounds.
            XCTAssertEqual(item.bbox.x * 900, line.x, accuracy: 12)
            XCTAssertGreaterThan(item.center.y * 1_400, line.top)
            XCTAssertLessThan(item.center.y * 1_400, line.top + 60)
        }

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(json["observation_id"] as? String, "screen-text-fixture")
        XCTAssertEqual(json["source"] as? String, "ocr")
        XCTAssertNotNil(json["ocr_ms"])
        XCTAssertNotNil(json["coverage_advice"])
        let jsonItems = try XCTUnwrap(json["items"] as? [[String: Any]])
        for item in jsonItems {
            XCTAssertNil(item["ref"], "OCR cannot manufacture native element refs")
            XCTAssertNil(item["type"], "Recognized text cannot claim native control semantics")
            XCTAssertNotNil(item["bbox"])
            XCTAssertNotNil(item["center"])
        }
        print("PHONE_OCR_FIXTURE items=\(result.items) ocr_ms=\(result.ocrMs)")
    }

    func testBlankScreenshotReportsNoTextWithoutInventingControls() async throws {
        let result = try await IOSPhoneScreenText.recognize(makeScreenshot(lines: [], observationID: "blank-screen"))
        XCTAssertEqual(result.observationID, "blank-screen")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.emptyReason, .noTextDetected)
        XCTAssertEqual(result.coverageAdvice, .noText)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(json["empty_reason"] as? String, "no_text_detected")
    }

    func testUnreadablePNGIsRejected() async throws {
        for data in [Data(), Data("not a PNG screenshot".utf8), Data([137, 80, 78, 71, 13, 10, 26, 10])] {
            do {
                _ = try await IOSPhoneScreenText.recognize(.init(
                    data: data, observationID: "invalid", width: 900, height: 1_400))
                XCTFail("Unreadable PNG data must fail before recognition")
            } catch {
                XCTAssertEqual(error as? IOSPhoneScreenText.Error, .invalidPNG)
            }
        }
    }

    func testValidJPEGDoesNotClaimToBeAPNGScreenshot() async throws {
        let png = try makeScreenshot(lines: [])
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(png.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        do {
            _ = try await IOSPhoneScreenText.recognize(.init(
                data: data as Data, observationID: "jpeg", width: 900, height: 1_400))
            XCTFail("A valid non-PNG image must not enter the screenshot OCR path")
        } catch {
            XCTAssertEqual(error as? IOSPhoneScreenText.Error, .invalidPNG)
        }
    }

    func testCancelledTaskDoesNotPublishAnOCRResult() async throws {
        let screenshot = try makeScreenshot(lines: [FixtureLine(text: "Amber", x: 90, top: 100)])
        let recognition = Task { try await IOSPhoneScreenText.recognize(screenshot) }
        recognition.cancel()
        do {
            _ = try await recognition.value
            XCTFail("A cancelled screen-text task cannot publish coordinates")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private struct FixtureLine {
        let text: String
        let x: Double
        let top: Double
    }

    /// Rasterizes test text with CoreText so the same Vision fixture can also run in a Mac harness.
    private func makeScreenshot(lines: [FixtureLine], observationID: String = "fixture") throws -> PhoneScreenshot {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 900, height: 1_400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_400))
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 54, nil)
        for line in lines {
            let text = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: line.x, y: 1_400 - line.top - 54)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(data: data as Data, observationID: observationID, width: 900, height: 1_400)
    }
}
