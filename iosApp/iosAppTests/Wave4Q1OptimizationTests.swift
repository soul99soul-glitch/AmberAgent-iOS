import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

final class Wave4Q1OptimizationTests: XCTestCase {

    // MARK: - 1. Opus C3: vchart 2.1 MB JS & sandbox HTML in-process cache

    func testVChartSandboxCacheReadsDiskOnceAndMatchesUnoptimizedAssemblyVerbatim() {
        var loadCounts: [String: Int] = [:]
        let htmlTemplate = """
        <!DOCTYPE html>
        <html>
        <head>
        <style>
        @font-face{src:url("https://amberagent.local/builtin-fonts/PlayfairDisplay-Regular.ttf");}
        @font-face{src:url("https://amberagent.local/builtin-fonts/Inter-Regular.ttf");}
        </style>
        <script src="./vchart.min.js"></script>
        </head>
        <body><div id="root"></div></body>
        </html>
        """
        let fakeVChartJS = "window.VChart={version:'test'};"

        let cache = IOSGenerativeSandboxHTMLCache { name, ext, subdirectory in
            let key = "\(subdirectory)/\(name).\(ext)"
            loadCounts[key, default: 0] += 1
            if name == "vchart-sandbox" && ext == "html" { return htmlTemplate }
            if name == "vchart.min" && ext == "js" { return fakeVChartJS }
            return nil
        }

        let first = cache.sandboxHTML(for: "vchart")
        let second = cache.sandboxHTML(for: "vchart")
        let third = cache.sandboxHTML(for: "vchart")

        let expected = htmlTemplate
            .replacingOccurrences(of: #"<script src="./vchart.min.js"></script>"#, with: "<script>\n\(fakeVChartJS)\n</script>")
            .replacingOccurrences(of: "https://amberagent.local/builtin-fonts/PlayfairDisplay-Regular.ttf", with: "PlayfairDisplay-Regular.ttf")
            .replacingOccurrences(of: "https://amberagent.local/builtin-fonts/Inter-Regular.ttf", with: "Inter-Regular.ttf")

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(third, expected)
        XCTAssertEqual(loadCounts["generative-libs/vchart-sandbox.html"], 1)
        XCTAssertEqual(loadCounts["generative-libs/vchart.min.js"], 1)
    }

    func testSandboxCachePreservesMissingResourceFallbackAndDoesNotNegativeCache() {
        var htmlAvailable = false
        var jsAvailable = false
        var htmlReads = 0
        var jsReads = 0

        let cache = IOSGenerativeSandboxHTMLCache { name, ext, _ in
            if name == "vchart-sandbox" && ext == "html" {
                htmlReads += 1
                return htmlAvailable ? #"<script src="./vchart.min.js"></script>"# : nil
            }
            if name == "vchart.min" && ext == "js" {
                jsReads += 1
                return jsAvailable ? "var VChart=1;" : nil
            }
            return nil
        }

        // Missing sandbox HTML returns nil (matches original fallback to errorPage).
        XCTAssertNil(cache.sandboxHTML(for: "vchart"))
        XCTAssertEqual(htmlReads, 1)
        XCTAssertEqual(jsReads, 0)

        // HTML present while JS is missing returns raw HTML without caching the degraded copy.
        htmlAvailable = true
        XCTAssertEqual(cache.sandboxHTML(for: "vchart"), #"<script src="./vchart.min.js"></script>"#)
        XCTAssertEqual(htmlReads, 2)
        XCTAssertEqual(jsReads, 1)

        // Once JS is available, it inlines and caches cleanly.
        jsAvailable = true
        XCTAssertEqual(cache.sandboxHTML(for: "vchart"), "<script>\nvar VChart=1;\n</script>")
        XCTAssertEqual(cache.sandboxHTML(for: "vchart"), "<script>\nvar VChart=1;\n</script>")
        XCTAssertEqual(htmlReads, 3)
        XCTAssertEqual(jsReads, 2)
    }

    func testSlidesSandboxCacheIsIndependentFromVChartAndNeverLoadsVChartJS() {
        var loadCounts: [String: Int] = [:]
        let slidesTemplate = #"url("https://amberagent.local/builtin-fonts/Inter-Regular.ttf")"#

        let cache = IOSGenerativeSandboxHTMLCache { name, ext, _ in
            loadCounts["\(name).\(ext)", default: 0] += 1
            if name == "slides-sandbox" && ext == "html" { return slidesTemplate }
            if name == "vchart-sandbox" && ext == "html" { return #"<script src="./vchart.min.js"></script>"# }
            if name == "vchart.min" && ext == "js" { return "VCHART" }
            return nil
        }

        XCTAssertEqual(cache.sandboxHTML(for: "slides"), #"url("Inter-Regular.ttf")"#)
        XCTAssertEqual(cache.sandboxHTML(for: "slides"), #"url("Inter-Regular.ttf")"#)
        XCTAssertNil(loadCounts["vchart.min.js"])
        XCTAssertEqual(loadCounts["slides-sandbox.html"], 1)

        XCTAssertEqual(cache.sandboxHTML(for: "vchart"), "<script>\nVCHART\n</script>")
        XCTAssertEqual(loadCounts["vchart.min.js"], 1)
    }

    // MARK: - 2. Opus C4: ProviderDetailView modelsPanel O(1) lookup, stable IDs & LazyVStack

    func testProviderModelListStableIDsSurviveInsertionsAndDistinguishTypesAndDuplicates() {
        let modelA = makeModel(modelId: "openrouter/model-a", type: .chat)
        let modelAImage = makeModel(modelId: "openrouter/model-a", type: .image)
        let modelB = makeModel(modelId: "openrouter/model-b", type: .chat)
        let modelBDup = makeModel(modelId: "openrouter/model-b", type: .chat)

        let before = ProviderModelListSupport.availableRowEntries(from: [modelA, modelAImage, modelB, modelBDup])
        XCTAssertEqual(before.map(\.id), [
            "openrouter/model-a|chat",
            "openrouter/model-a|image",
            "openrouter/model-b|chat",
            "openrouter/model-b|chat#1",
        ])
        XCTAssertEqual(before.map(\.showsDivider), [true, true, true, false])

        // Inserting a new model at the front must NOT shift the identity of existing models.
        let prepended = makeModel(modelId: "openrouter/model-0", type: .chat)
        let after = ProviderModelListSupport.availableRowEntries(from: [prepended, modelA, modelAImage, modelB])
        XCTAssertEqual(after[1].id, before[0].id)
        XCTAssertEqual(after[2].id, before[1].id)
        XCTAssertEqual(after[3].id, before[2].id)

        // Enabled models use their persistent UUIDs so edits/deletions stay stably anchored.
        let enabledEntries = ProviderModelListSupport.enabledRowEntries(from: [modelA, modelB])
        XCTAssertEqual(enabledEntries.map(\.id), [modelA.id.description(), modelB.id.description()])
        XCTAssertEqual(enabledEntries.map(\.showsDivider), [true, false])
    }

    func testProviderModelLookupPreservesFirstMatchSemanticsAndDefaultSelection() {
        let firstChat = makeModel(modelId: "openai/gpt-5", displayName: "First", type: .chat)
        let duplicateChat = makeModel(modelId: "openai/gpt-5", displayName: "Second", type: .chat)
        let imageModel = makeModel(modelId: "openai/gpt-5", displayName: "Image", type: .image)
        let embeddingModel = makeModel(modelId: "openai/text-embedding-3", displayName: "Embed", type: .embedding)

        let enabledModels = [firstChat, duplicateChat, imageModel, embeddingModel]
        let lookup = ProviderModelListSupport.enabledModelLookup(from: enabledModels)

        // Matches original `enabledModels.first { $0.modelId == ... && $0.type == ... }`
        XCTAssertEqual(lookup[ProviderModelListSupport.lookupKey(for: duplicateChat)]?.id, firstChat.id)
        XCTAssertEqual(lookup[ProviderModelListSupport.lookupKey(for: imageModel)]?.id, imageModel.id)
        XCTAssertEqual(lookup[ProviderModelListSupport.lookupKey(for: embeddingModel)]?.id, embeddingModel.id)

        XCTAssertEqual(
            ProviderModelListSupport.defaultSelectionTitle(
                for: firstChat,
                currentChatModelId: firstChat.id,
                currentImageModelId: imageModel.id
            ),
            "聊天默认"
        )
        XCTAssertEqual(
            ProviderModelListSupport.defaultSelectionTitle(
                for: imageModel,
                currentChatModelId: firstChat.id,
                currentImageModelId: imageModel.id
            ),
            "生图默认"
        )
        XCTAssertNil(
            ProviderModelListSupport.defaultSelectionTitle(
                for: embeddingModel,
                currentChatModelId: firstChat.id,
                currentImageModelId: imageModel.id
            )
        )
    }

    func testProviderDetailViewModelsPanelUsesLazyVStackWithoutOffsetIdentity() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testDirectory.deletingLastPathComponent()
                .appendingPathComponent("iosApp/ProviderDetailView.swift"),
            encoding: .utf8
        )
        let modelsPanelSection = source
            .components(separatedBy: "private var modelsPanel: some View")
            .last?
            .components(separatedBy: "private var modelActions: some View")
            .first ?? ""

        XCTAssertTrue(modelsPanelSection.contains("LazyVStack(spacing: 0)"))
        XCTAssertTrue(modelsPanelSection.contains("ProviderLazyFormGroup"))
        XCTAssertTrue(modelsPanelSection.contains("ProviderModelListSupport.enabledModelLookup"))
        XCTAssertFalse(modelsPanelSection.contains("id: \\.offset"))
    }

    // MARK: - 3. Astra rule store: off-main compact JSON encoding & FIFO/legacy compatibility

    @MainActor
    func testProceduralRuleStoreWritesCompactJSONAndLoadsLegacyPrettyPrintedJSON() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave4q1-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        // Seed a legacy pretty-printed JSON file on disk (with indentation and newlines).
        let legacyRule = IOSProceduralRule(
            id: "local_rule_legacy01",
            title: "既有规则",
            instruction: "先跑受影响单测再提交。",
            scope: IOSProceduralRule.scopeGlobal,
            sourceEventId: "evt-legacy",
            status: .active,
            hitCount: 3,
            createdAt: 1_000,
            updatedAt: 2_000
        )
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let prettyData = try prettyEncoder.encode([legacyRule])
        let prettyText = try XCTUnwrap(String(data: prettyData, encoding: .utf8))
        XCTAssertTrue(prettyText.contains("\n"), "Precondition: legacy file should be pretty-printed")
        try prettyData.write(to: storageURL, options: [.atomic])

        // Store reads legacy pretty-printed file cleanly.
        let store = IOSProceduralRuleStore(storageURL: storageURL, clockMs: { 5_000 })
        XCTAssertEqual(store.rules, [legacyRule])

        // Trigger persistence via hit-count increment (the hot send path).
        let injected = store.selectActiveForInjection(conversationId: "conv-1", recordHit: true)
        XCTAssertEqual(injected.first?.hitCount, 4)
        store.flushPersistenceForTesting()

        // Persisted JSON on disk is now compact (single line, no pretty-print newlines).
        let compactData = try Data(contentsOf: storageURL)
        let compactText = try XCTUnwrap(String(data: compactData, encoding: .utf8))
        XCTAssertFalse(compactText.contains("\n"), "Persisted procedural rules should use compact JSON")
        XCTAssertLessThan(compactData.count, prettyData.count)

        // Reloading from compact JSON restores exact state including updated hitCount.
        let reloaded = IOSProceduralRuleStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertEqual(reloaded.rules.first?.id, legacyRule.id)
        XCTAssertEqual(reloaded.rules.first?.hitCount, 4)
        XCTAssertEqual(reloaded.rules.first?.status, .active)
    }

    private final class StepClock: @unchecked Sendable {
        private var current: Int64
        init(_ initial: Int64) { self.current = initial }
        func next() -> Int64 {
            current += 10
            return current
        }
    }

    @MainActor
    func testProceduralRuleStoreOffMainPersistencePreservesFIFOOrderAcrossHitAndRevoke() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave4q1-rules-fifo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let clock = StepClock(10_000)
        let store = IOSProceduralRuleStore(storageURL: storageURL, clockMs: { clock.next() })

        guard case .proposed(let created, _) = store.proposeLocal(
            title: "FIFO 顺序检查",
            instruction: "修改存储后确认 FIFO 与撤销顺序一致。"
        ) else {
            XCTFail("Expected proposed rule")
            return
        }
        _ = try store.confirmLocal(id: created.id)

        // Rapidly enqueue multiple hit increments followed immediately by revoke on the main thread.
        for _ in 0..<5 {
            let active = store.selectActiveForInjection(conversationId: "conv-fifo", recordHit: true)
            XCTAssertEqual(active.count, 1)
        }
        let revoked = try store.revokeLocal(id: created.id)
        XCTAssertEqual(revoked.status, .revoked)
        XCTAssertEqual(revoked.hitCount, 5)
        XCTAssertTrue(store.selectActiveForInjection(conversationId: "conv-fifo", recordHit: true).isEmpty)

        // Wait for the serial FIFO background queue to encode and atomically write all queued snapshots.
        store.flushPersistenceForTesting()

        let reloaded = IOSProceduralRuleStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertEqual(reloaded.rules.first?.id, created.id)
        XCTAssertEqual(reloaded.rules.first?.status, .revoked)
        XCTAssertEqual(reloaded.rules.first?.hitCount, 5)
        XCTAssertTrue(reloaded.selectActiveForInjection(conversationId: "conv-fifo", recordHit: false).isEmpty)
    }

    // MARK: - Helpers

    private func makeModel(
        modelId: String,
        displayName: String = "",
        type: ModelType
    ) -> Model {
        Model(
            modelId: modelId,
            displayName: displayName.isEmpty ? modelId : displayName,
            id: KotlinUuid.companion.random(),
            type: type,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
    }
}
