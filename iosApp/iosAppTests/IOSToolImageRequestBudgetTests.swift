import ImageIO
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Request-side image budget, image token estimate and screenshot encoding for phone runs.
@MainActor
final class IOSToolImageRequestBudgetTests: XCTestCase {
    // MARK: Budget selection

    func testKeepsImagesOnlyForLatestToolResultsAndKeepsTheirText() throws {
        let messages = (1...5).map { assistant([screenshotTool(id: "s\($0)")]) }
        let budgeted = IOSToolImageRequestBudget.apply(messages)

        XCTAssertEqual(budgeted.count, messages.count)
        for (index, message) in budgeted.enumerated() {
            let tool = try XCTUnwrap(message.parts.first as? UIMessagePart.Tool)
            XCTAssertEqual(tool.toolCallId, "s\(index + 1)")
            XCTAssertEqual((tool.output.first as? UIMessagePart.Text)?.text, #"{"screenshot_observation_id":"s\#(index + 1)"}"#)
            if index < 3 {
                XCTAssertFalse(tool.output.contains { $0 is UIMessagePart.Image })
                XCTAssertEqual((tool.output.last as? UIMessagePart.Text)?.text,
                               IOSToolImageRequestBudget.placeholderText(step: index + 1))
            } else {
                XCTAssertTrue(tool.output.last is UIMessagePart.Image, "latest two keep their screenshot")
                XCTAssertTrue(message === messages[index], "unchanged messages are reused as-is")
            }
        }
        XCTAssertEqual(IOSToolImageRequestBudget.placeholderText(step: 1), "[较早的截图已省略：第 1 步]")
    }

    func testCountsToolResultsNotMessagesWhenOneAssistantHoldsManySteps() throws {
        let message = assistant((1...4).map { screenshotTool(id: "s\($0)") })
        let parts = IOSToolImageRequestBudget.apply([message])[0].parts.compactMap { $0 as? UIMessagePart.Tool }
        XCTAssertEqual(parts.map { $0.output.contains { $0 is UIMessagePart.Image } }, [false, false, true, true])
    }

    func testUserAttachedImagesAreNeverTouched() throws {
        let userImage = UIMessagePart.Image(url: "data:image/png;base64,VVNFUg==", metadata: nil)
        let user = message(role: MessageRole.user, [UIMessagePart.Text(text: "看图", metadata: nil), userImage])
        let messages = [user] + (1...4).map { assistant([screenshotTool(id: "s\($0)")]) }
        let budgeted = IOSToolImageRequestBudget.apply(messages, keepRecent: 1)
        XCTAssertTrue(budgeted[0] === user)
        XCTAssertEqual((budgeted[0].parts.last as? UIMessagePart.Image)?.url, userImage.url)
    }

    func testPlaceholdersAreStableAcrossRoundsAndIdempotent() throws {
        let rounds = (3...8).map { count in (1...count).map { assistant([screenshotTool(id: "s\($0)")]) } }
        // Same canonical prefix between rounds: share message objects like the real transcript.
        let canonical = rounds.last!
        var previous: [String]?
        for count in 3...8 {
            let view = IOSToolImageRequestBudget.apply(Array(canonical.prefix(count)))
            let texts = view.map(outputSignature)
            if let previous {
                // Everything except the newest kept window is byte-identical to the last round
                // (the window only moves forward; a dropped image stays dropped).
                XCTAssertEqual(Array(texts.prefix(previous.count - 2)), Array(previous.prefix(previous.count - 2)))
            }
            // Re-applying to an already budgeted view (background continuation) changes nothing.
            XCTAssertEqual(IOSToolImageRequestBudget.apply(view).map(outputSignature), texts)
            previous = texts
        }
        // A background view that already carries placeholders keeps the same step numbering.
        let edited = IOSToolImageRequestBudget.apply(Array(canonical.prefix(5)))
        let continued = IOSToolImageRequestBudget.apply(edited + [assistant([screenshotTool(id: "s6")])])
        XCTAssertEqual(continued.map(outputSignature),
                       IOSToolImageRequestBudget.apply(Array(canonical.prefix(6))).map(outputSignature))
    }

    func testPreparedRequestDropsOldScreenshotsThroughCoordinator() throws {
        let png = Self.syntheticScreenshotPNG()
        let messages = (1...6).map { assistant([screenshotTool(id: "s\($0)", imageURL: "data:image/png;base64,\(png.base64EncodedString())")]) }
        let before = IOSContextCompactionCoordinator.estimatedTokensForRequest(messages)
        let after = IOSContextCompactionCoordinator.estimatedTokensForRequest(IOSToolImageRequestBudget.apply(messages))
        XCTAssertLessThan(after, before / 2)
    }

    // MARK: Missing blobs

    func testMissingBlobImagesBecomeTextAndDoNotOccupyTheWindow() throws {
        let messages = [
            assistant([screenshotTool(id: "s1")]),
            assistant([screenshotTool(id: "s2", missingBlob: true)]),
            assistant([screenshotTool(id: "s3")]),
            assistant([screenshotTool(id: "s4")]),
            assistant([screenshotTool(id: "s5", missingBlob: true)]),
        ]
        let outputs = IOSToolImageRequestBudget.apply(messages).map(outputSignature)
        let missing = "T:" + IOSToolImageRequestBudget.missingBlobText
        XCTAssertTrue(outputs[0].hasSuffix("T:" + IOSToolImageRequestBudget.placeholderText(step: 1)))
        XCTAssertTrue(outputs[1].hasSuffix(missing))
        XCTAssertTrue(outputs[2].hasSuffix("I:data:image/png;base64,iVBORw0KGgo="), "missing blobs do not take a kept slot")
        XCTAssertTrue(outputs[3].hasSuffix("I:data:image/png;base64,iVBORw0KGgo="))
        XCTAssertTrue(outputs[4].hasSuffix(missing), "a missing blob is never sent even when it is the latest")
        XCTAssertFalse(outputs.joined().contains(Self.missingBlobURL))

        // Numbering is unchanged when the view is budgeted again (background continuation).
        XCTAssertEqual(IOSToolImageRequestBudget.apply(IOSToolImageRequestBudget.apply(messages)).map(outputSignature), outputs)
    }

    func testMissingBlobUserImageIsUntouchedAndNotPricedAsImage() throws {
        let missing = UIMessagePart.Image(url: Self.missingBlobURL, metadata: Self.missingBlobMetadata())
        let user = message(role: MessageRole.user, [missing])
        XCTAssertTrue(IOSToolImageRequestBudget.apply([user])[0] === user)
        XCTAssertTrue(IOSToolImageRequestBudget.isMissingBlobPlaceholder(missing))
        XCTAssertLessThan(IOSContextCompactionCoordinator.estimatedTokensForRequest([user]), 50)

        // An upper layer may rebuild the part without metadata; the placeholder url still identifies it.
        let stripped = UIMessagePart.Image(url: Self.missingBlobURL, metadata: nil)
        XCTAssertTrue(IOSToolImageRequestBudget.isMissingBlobPlaceholder(stripped))
        XCTAssertLessThan(IOSContextCompactionCoordinator.estimatedTokensForRequest([message(role: MessageRole.user, [stripped])]), 50)

        let tiny = "data:image/png;base64,\(Self.syntheticScreenshotPNG(width: 2, height: 2).base64EncodedString())"
        let real = message(role: MessageRole.user, [UIMessagePart.Image(url: tiny, metadata: nil)])
        XCTAssertFalse(IOSToolImageRequestBudget.isMissingBlobPlaceholder(real.parts[0] as! UIMessagePart.Image))
        XCTAssertGreaterThanOrEqual(IOSContextCompactionCoordinator.estimatedTokensForRequest([real]), 258)
    }

    func testMissingBlobWithoutMetadataInNestedToolOutputIsReplaced() throws {
        let nested = UIMessagePart.Tool(
            toolCallId: "inner", toolName: "phone_observe", input: "{}",
            output: [UIMessagePart.Image(url: Self.missingBlobURL, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        let outer = UIMessagePart.Tool(
            toolCallId: "outer", toolName: "phone_run_flow", input: "{}",
            output: [UIMessagePart.Text(text: "flow", metadata: nil), nested],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        let messages = [assistant([outer]), assistant([screenshotTool(id: "s1")]), assistant([screenshotTool(id: "s2")])]
        let budgeted = IOSToolImageRequestBudget.apply(messages)
        let inner = try XCTUnwrap((budgeted[0].parts[0] as? UIMessagePart.Tool)?.output.last as? UIMessagePart.Tool)
        XCTAssertEqual((inner.output.first as? UIMessagePart.Text)?.text, IOSToolImageRequestBudget.missingBlobText)
        // The missing blob does not occupy the window: both real screenshots stay.
        XCTAssertTrue(budgeted[1] === messages[1])
        XCTAssertTrue(budgeted[2] === messages[2])
    }

    // MARK: Gauge memo

    func testGaugeDoesNotRebudgetAnUnchangedTranscript() throws {
        let messages = (1...6).map { assistant([screenshotTool(id: "g\($0)")]) }
        let first = ContextCompactionEditTestSupport.nextTurnOccupancyTokens(
            messages: messages, compactSourceIds: [], compactCreatedAt: 0)
        let runs = IOSToolImageRequestBudget.applyRunCountForTesting
        for _ in 0..<20 {
            XCTAssertEqual(ContextCompactionEditTestSupport.nextTurnOccupancyTokens(
                messages: messages, compactSourceIds: [], compactCreatedAt: 0), first)
        }
        XCTAssertEqual(IOSToolImageRequestBudget.applyRunCountForTesting, runs, "unchanged transcript reuses the budgeted view")

        // A changed transcript is budgeted again, and unchanged tool results keep their identity
        // so the identity-keyed token memo still hits.
        let before = IOSToolImageRequestBudget.memoizedApply(messages)
        let after = IOSToolImageRequestBudget.memoizedApply(messages + [assistant([screenshotTool(id: "g7")])])
        XCTAssertEqual(IOSToolImageRequestBudget.applyRunCountForTesting, runs + 1)
        XCTAssertTrue(after[0].parts[0] === before[0].parts[0])

        // The gauge counts what is sent: only the latest two screenshots are priced.
        XCTAssertEqual(first, IOSContextCompactionCoordinator.estimatedTokensForRequest(IOSToolImageRequestBudget.apply(messages)))
    }

    // MARK: Estimate

    func testImageEstimateUsesPixelSizeLikeProviders() throws {
        let png = Self.syntheticScreenshotPNG()
        let url = "data:image/png;base64,\(png.base64EncodedString())"
        let size = try XCTUnwrap(IOSImageTokenEstimate.pixelSize(base64: url[url.range(of: ";base64,")!.upperBound...]))
        XCTAssertEqual(size.width, 1206)
        XCTAssertEqual(size.height, 2622)
        // Gemini tiling (2 x 4 x 258) is the most expensive provider for this size.
        XCTAssertEqual(IOSImageTokenEstimate.estimatedTokens(url: url), 2_064)
        XCTAssertEqual(IOSImageTokenEstimate.providerTokens(width: 300, height: 300), 258)
        XCTAssertEqual(IOSImageTokenEstimate.providerTokens(width: 589, height: 1280), 1_105)
        XCTAssertEqual(IOSImageTokenEstimate.estimatedTokens(url: "https://example.com/a.png"),
                       IOSImageTokenEstimate.unknownImageTokens)

        let jpeg = try XCTUnwrap(IOSPhoneScreenshotEncoder.encodeForModel(png))
        let jpegTokens = IOSImageTokenEstimate.estimatedTokens(url: jpeg.dataURL)
        XCTAssertEqual(jpegTokens, IOSImageTokenEstimate.providerTokens(width: jpeg.pixelWidth, height: jpeg.pixelHeight))
        XCTAssertLessThan(jpegTokens, 2_064)

        // The coordinator estimate counts images at that real cost (it was a flat 4,500 chars).
        let message = assistant([screenshotTool(id: "s1", imageURL: url)])
        XCTAssertGreaterThan(IOSContextCompactionCoordinator.estimatedTokensForRequest([message]), 2_064)
    }

    func testOversizedPayloadRaisesEstimateBeyondPixelCost() {
        // Undecodable but huge payload: priced by bytes, not the flat fallback.
        let payload = String(repeating: "A", count: 4_000_000)
        XCTAssertEqual(IOSImageTokenEstimate.estimatedTokens(url: "data:image/png;base64,\(payload)"),
                       3_000_000 / IOSImageTokenEstimate.payloadBytesPerToken)
    }

    // MARK: Encoding

    func testScreenshotEncoderProducesSmallerBoundedJPEG() throws {
        let png = Self.syntheticScreenshotPNG()
        let encoded = try XCTUnwrap(IOSPhoneScreenshotEncoder.encodeForModel(png))
        XCTAssertEqual(encoded.mimeType, "image/jpeg")
        XCTAssertEqual(Array(encoded.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(max(encoded.pixelWidth, encoded.pixelHeight), IOSPhoneScreenshotEncoder.maxLongEdgePixels)
        XCTAssertEqual(Double(encoded.pixelWidth) / Double(encoded.pixelHeight), 1206.0 / 2622.0, accuracy: 0.01)
        // Flat synthetic UI compresses well as PNG (~2x here); real screenshots shrink ~5x (Settings: 321 KB -> 61 KB).
        XCTAssertLessThan(encoded.data.count, png.count * 3 / 4)
        print("[ScreenshotEncoder] png=\(png.count)B base64=\(png.base64EncodedString().count) -> jpeg=\(encoded.data.count)B base64=\(encoded.data.base64EncodedString().count) \(encoded.pixelWidth)x\(encoded.pixelHeight)")

        let url = IOSPhoneControlToolExecutor.modelImageURL(png)
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))

        // Never upscales small images.
        let small = try XCTUnwrap(IOSPhoneScreenshotEncoder.encodeForModel(Self.syntheticScreenshotPNG(width: 300, height: 600)))
        XCTAssertEqual(small.pixelWidth, 300)
        XCTAssertEqual(small.pixelHeight, 600)
        XCTAssertNil(IOSPhoneScreenshotEncoder.encodeForModel(Data("not an image".utf8)))
    }

    // MARK: Fixtures

    /// Screenshot-like PNG: white background, nav bar, list rows with text, a colored button.
    static func syntheticScreenshotPNG(width: Int = 1206, height: Int = 2622) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemGroupedBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = CGFloat(width) / 402
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 34 * scale)]
            ("设置 Settings" as NSString).draw(at: CGPoint(x: 16 * scale, y: 100 * scale), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17 * scale), .foregroundColor: UIColor.label]
            var y = 170 * scale
            var row = 0
            while y < CGFloat(height) - 60 * scale {
                UIColor.white.setFill()
                context.fill(CGRect(x: 16 * scale, y: y, width: CGFloat(width) - 32 * scale, height: 44 * scale))
                UIColor(hue: CGFloat(row % 7) / 7, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 28 * scale, y: y + 8 * scale, width: 28 * scale, height: 28 * scale))
                ("第 \(row + 1) 项 Wi-Fi 蓝牙 通知 Notifications 12:3\(row % 10)" as NSString)
                    .draw(at: CGPoint(x: 68 * scale, y: y + 11 * scale), withAttributes: body)
                y += 52 * scale
                row += 1
            }
        }
        return image.pngData()!
    }

    static var missingBlobURL: String { ConversationBlobsKt.MISSING_BLOB_PLACEHOLDER_URL }

    static func missingBlobMetadata() -> [String: Kotlinx_serialization_jsonJsonElement] {
        [IOSToolImageRequestBudget.missingBlobMetadataKey:
            Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: #""amber-blob://lost.png""#)]
    }

    private func screenshotTool(id: String, imageURL: String = "data:image/png;base64,iVBORw0KGgo=",
                                missingBlob: Bool = false) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: id,
            toolName: "phone_observe",
            input: "{}",
            output: [
                UIMessagePart.Text(text: #"{"screenshot_observation_id":"\#(id)"}"#, metadata: nil),
                missingBlob
                    ? UIMessagePart.Image(url: Self.missingBlobURL, metadata: Self.missingBlobMetadata())
                    : UIMessagePart.Image(url: imageURL, metadata: nil),
            ],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func assistant(_ parts: [UIMessagePart]) -> UIMessage {
        message(role: MessageRole.assistant, parts)
    }

    private func message(role: MessageRole, _ parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 10, day: 16, hour: 0, minute: 0, second: 0, nanosecond: 0),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func outputSignature(_ message: UIMessage) -> String {
        message.parts.compactMap { $0 as? UIMessagePart.Tool }.flatMap(\.output).map { part in
            if let text = part as? UIMessagePart.Text { return "T:" + text.text }
            if let image = part as? UIMessagePart.Image { return "I:" + image.url }
            return "?"
        }.joined(separator: "|")
    }
}
