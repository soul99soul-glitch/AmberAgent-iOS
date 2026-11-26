import XCTest
@testable import iosApp
@testable import SwiftStreamingMarkdown

@MainActor
final class Wave4A2OptimizationTests: XCTestCase {
    override func tearDown() async throws {
        CodeBlockHighlightCache.shared.removeAll()
    }

    // MARK: - CodeBlockView Highlight Global Cache

    func testCodeBlockHighlightCachePopulatesAndHitsOnInit() async throws {
        CodeBlockHighlightCache.shared.removeAll()

        let code = "func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}"
        let initialView = CodeBlockView(language: "swift", code: code)
        XCTAssertFalse(
            initialView.didPrepopulateHighlightFromCache,
            "Cold cache must miss during initial CodeBlockView.init"
        )

        let appearance = CodeBlockView.currentAppearanceKey()
        let highlighted = await CodeBlockView.highlight(
            code: code,
            language: "swift",
            appearance: appearance
        )
        let attributed = try XCTUnwrap(highlighted)
        XCTAssertEqual(String(attributed.characters), code)

        let reopenedView = CodeBlockView(language: "swift", code: code)
        XCTAssertTrue(
            reopenedView.didPrepopulateHighlightFromCache,
            "Reopened CodeBlockView.init must synchronously hit global highlight cache"
        )
    }

    func testCodeBlockHighlightCacheMatchesCollapsedPrefixOnInit() {
        CodeBlockHighlightCache.shared.removeAll()

        let longCode = String(repeating: "let value = 42\n", count: 50)
        XCTAssertGreaterThan(longCode.count, 500)
        let collapsedPrefix = CodeBlockView.displayedCode(for: longCode, autoCollapse: true, expanded: false)
        XCTAssertEqual(collapsedPrefix.count, 300)

        let appearance = CodeBlockView.currentAppearanceKey()
        let css = CodeBlockView.syntaxHighlightingCss(for: appearance)

        // Caching only the full code must not falsely hit when autoCollapse renders the 300-char prefix.
        CodeBlockHighlightCache.shared.store(
            AttributedString(longCode),
            for: longCode,
            language: "swift",
            css: css,
            appearance: appearance
        )
        let missView = CodeBlockView(language: "swift", code: longCode, autoCollapse: true)
        XCTAssertFalse(missView.didPrepopulateHighlightFromCache)

        // Caching the collapsed prefix enables immediate first-frame hit on init.
        CodeBlockHighlightCache.shared.store(
            AttributedString(collapsedPrefix),
            for: collapsedPrefix,
            language: "swift",
            css: css,
            appearance: appearance
        )
        let hitView = CodeBlockView(language: "swift", code: longCode, autoCollapse: true)
        XCTAssertTrue(hitView.didPrepopulateHighlightFromCache)
    }

    func testCodeBlockHighlightCacheIsolatesAppearanceCssLanguageAndCode() {
        let cache = CodeBlockHighlightCache()
        let code = "let x = 1"
        let lightCss = "code { color: #111111; }"
        let darkCss = "code { color: #EEEEEE; }"

        var lightAttributed = AttributedString(code)
        lightAttributed.foregroundColor = .black
        var darkAttributed = AttributedString(code)
        darkAttributed.foregroundColor = .white
        var pythonAttributed = AttributedString(code)
        pythonAttributed.foregroundColor = .blue

        cache.store(lightAttributed, for: code, language: "swift", css: lightCss, appearance: "light")
        cache.store(darkAttributed, for: code, language: "swift", css: darkCss, appearance: "dark")
        cache.store(pythonAttributed, for: code, language: "python", css: lightCss, appearance: "light")

        // Distinct appearance / CSS isolation.
        XCTAssertEqual(
            cache.attributedString(for: code, language: "swift", css: lightCss, appearance: "light"),
            lightAttributed
        )
        XCTAssertEqual(
            cache.attributedString(for: code, language: "swift", css: darkCss, appearance: "dark"),
            darkAttributed
        )
        XCTAssertNil(
            cache.attributedString(for: code, language: "swift", css: lightCss, appearance: "dark"),
            "Same CSS under different appearance must not bleed across light/dark"
        )
        XCTAssertNil(
            cache.attributedString(for: code, language: "swift", css: darkCss, appearance: "light"),
            "Different CSS under same code must not collide"
        )

        // Language isolation.
        XCTAssertEqual(
            cache.attributedString(for: code, language: "python", css: lightCss, appearance: "light"),
            pythonAttributed
        )
        XCTAssertNil(
            cache.attributedString(for: code, language: "rust", css: lightCss, appearance: "light")
        )

        // Same-length different code isolation.
        XCTAssertNil(
            cache.attributedString(for: "let y = 2", language: "swift", css: lightCss, appearance: "light")
        )
    }

    func testCodeBlockHighlightCacheHasBoundsAndThreadSafeAccess() async {
        XCTAssertGreaterThan(CodeBlockHighlightCache.shared.countLimit, 0)
        XCTAssertGreaterThan(CodeBlockHighlightCache.shared.totalCostLimit, 0)

        let cache = CodeBlockHighlightCache(countLimit: 64, totalCostLimit: 256 * 1024)
        let css = "code { color: #FCFAF7; }"

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<40 {
                        let code = "let item_\(worker)_\(index) = \(index)"
                        let appearance = index.isMultiple(of: 2) ? "dark" : "light"
                        let value = AttributedString(code)
                        cache.store(value, for: code, language: "swift", css: css, appearance: appearance)
                        if let fetched = cache.attributedString(
                            for: code,
                            language: "swift",
                            css: css,
                            appearance: appearance
                        ) {
                            XCTAssertEqual(String(fetched.characters), code)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Codex Image Extraction JSON vs SSE Equivalence

    func testCodexImageExtractionPlainJSONMultiImagePreservesOrderAndDeduplicates() {
        let json = """
        {
          "id": "resp_done_1",
          "status": "completed",
          "output": [
            {"type": "image_generation_call", "status": "completed", "result": "data:image/png;base64,SU1HMQ=="},
            {"type": "image_generation_call", "status": "completed", "result": "data:image/png;base64,SU1HMg=="},
            {"type": "image_generation_call", "status": "completed", "result": "data:image/png;base64,SU1HMQ=="}
          ]
        }
        """

        let extraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(json.utf8))

        XCTAssertEqual(
            extraction.images,
            ["data:image/png;base64,SU1HMQ==", "data:image/png;base64,SU1HMg=="]
        )
        XCTAssertNil(extraction.failureReason)
        XCTAssertNil(extraction.pendingResponseId)
    }

    func testCodexImageExtractionLargeJSONPayloadSkipsSSEScanCleanly() {
        let largeBase64 = String(repeating: "A", count: 1_024 * 1024)
        let payload = #"{"id":"resp_big","status":"completed","output":[{"type":"image_generation_call","status":"completed","result":"\#(largeBase64)"}]}"#

        let extraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(payload.utf8))

        XCTAssertEqual(extraction.images.count, 1)
        XCTAssertEqual(extraction.images.first?.count, largeBase64.count)
        XCTAssertNil(extraction.failureReason)
        XCTAssertNil(extraction.pendingResponseId)
    }

    func testCodexImageExtractionPureSSEMultiImagePreservesOrderAndDeduplicates() {
        let sse = [
            ": keepalive",
            "event: response.output_item.done",
            #"data: {"type":"response.output_item.done","item":{"type":"image_generation_call","status":"completed","result":"img_first"}}"#,
            "",
            "event: response.output_item.done",
            #"data: {"type":"response.output_item.done","item":{"type":"image_generation_call","status":"completed","result":"img_second"}}"#,
            "",
            "event: response.completed",
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"image_generation_call","result":"img_first"},{"type":"image_generation_call","result":"img_third"}]}}"#,
            "",
            "data: [DONE]",
            ""
        ].joined(separator: "\n")

        let extraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(sse.utf8))

        XCTAssertEqual(extraction.images, ["img_first", "img_second", "img_third"])
        XCTAssertNil(extraction.failureReason)
        XCTAssertNil(extraction.pendingResponseId)
    }

    func testCodexImageExtractionPendingResponseIDForJSONAndSSE() {
        let pendingJSON = #"{"id":"resp_json_pending","status":"in_progress"}"#
        let jsonExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(pendingJSON.utf8))
        XCTAssertTrue(jsonExtraction.images.isEmpty)
        XCTAssertEqual(jsonExtraction.pendingResponseId, "resp_json_pending")

        let nestedPendingJSON = #"{"type":"response.in_progress","response":{"id":"resp_nested_pending","status":"in_progress"}}"#
        let nestedExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(nestedPendingJSON.utf8))
        XCTAssertTrue(nestedExtraction.images.isEmpty)
        XCTAssertEqual(nestedExtraction.pendingResponseId, "resp_nested_pending")
        XCTAssertEqual(nestedExtraction.failureReason, "response status=in_progress")

        let pendingSSE = """
        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_sse_pending","status":"in_progress"}}

        data: [DONE]
        """
        let sseExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(pendingSSE.utf8))
        XCTAssertTrue(sseExtraction.images.isEmpty)
        XCTAssertEqual(sseExtraction.pendingResponseId, "resp_sse_pending")
        XCTAssertEqual(sseExtraction.failureReason, "response status=in_progress")
    }

    func testCodexImageExtractionFailureReasonsForJSONAndSSE() {
        let errorJSON = #"{"error":{"message":"Quota exceeded"}}"#
        let errorExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(errorJSON.utf8))
        XCTAssertTrue(errorExtraction.images.isEmpty)
        XCTAssertEqual(errorExtraction.failureReason, "Quota exceeded")
        XCTAssertNil(errorExtraction.pendingResponseId)

        let refusalJSON = #"{"output":[{"content":[{"refusal":"Blocked by safety policy"}]}]}"#
        let refusalExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(refusalJSON.utf8))
        XCTAssertTrue(refusalExtraction.images.isEmpty)
        XCTAssertEqual(refusalExtraction.failureReason, "Blocked by safety policy")

        let eventTypeOnlyJSON = #"{"type":"response.failed"}"#
        let eventTypeExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(eventTypeOnlyJSON.utf8))
        XCTAssertTrue(eventTypeExtraction.images.isEmpty)
        XCTAssertEqual(
            eventTypeExtraction.failureReason,
            "Codex SSE 未包含 image_generation_call.result；events=response.failed"
        )

        let errorSSE = """
        event: response.failed
        data: {"type":"response.failed","response":{"status":"failed","incomplete_details":{"reason":"content_filter"}}}

        """
        let sseFailure = IOSImageGenerationRepository.codexImageExtraction(from: Data(errorSSE.utf8))
        XCTAssertTrue(sseFailure.images.isEmpty)
        XCTAssertEqual(sseFailure.failureReason, "content_filter")
    }

    func testCodexImageExtractionMalformedAndFallbackBodies() {
        let emptyExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data("   \n\t ".utf8))
        XCTAssertTrue(emptyExtraction.images.isEmpty)
        XCTAssertNil(emptyExtraction.failureReason)
        XCTAssertNil(emptyExtraction.pendingResponseId)

        let plainText = "502 Bad Gateway: upstream unavailable"
        let plainExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(plainText.utf8))
        XCTAssertTrue(plainExtraction.images.isEmpty)
        XCTAssertEqual(plainExtraction.failureReason, plainText)

        let longText = String(repeating: "x", count: 700)
        let longExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(longText.utf8))
        XCTAssertEqual(longExtraction.failureReason?.count, 500)

        let arrayBody = #"["unexpected_root_array"]"#
        let arrayExtraction = IOSImageGenerationRepository.codexImageExtraction(from: Data(arrayBody.utf8))
        XCTAssertTrue(arrayExtraction.images.isEmpty)
        XCTAssertEqual(arrayExtraction.failureReason, arrayBody)
    }
}
