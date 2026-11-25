import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class Wave3A4OptimizationTests: IOSChatKernelRunHostTestCase {

    // MARK: - Opus G3: Base + Draft Occupancy Equivalence

    func testOccupancyBasePlusDraftStrictlyMatchesMonolithicCalculation() {
        let nowSecond: Int32 = 10
        let assistantWithUsage = makeAssistantMessage(
            text: "这里是已完成的回复内容",
            promptTokens: 6_400,
            completionTokens: 320,
            second: nowSecond
        )
        let tool = UIMessagePart.Tool(
            toolCallId: "tool-1",
            toolName: "read_file",
            input: #"{"path":"a.swift"}"#,
            output: [UIMessagePart.Text(text: String(repeating: "a", count: 800), metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantWithTool = UIMessage(
            id: assistantWithUsage.id,
            role: assistantWithUsage.role,
            parts: assistantWithUsage.parts + [tool],
            annotations: assistantWithUsage.annotations,
            createdAt: assistantWithUsage.createdAt,
            finishedAt: assistantWithUsage.finishedAt,
            modelId: assistantWithUsage.modelId,
            usage: assistantWithUsage.usage,
            translation: assistantWithUsage.translation
        )
        let oldUser = UIMessage.companion.user(prompt: "Earlier long prompt " + String(repeating: "x", count: 600))
        let tailUser = UIMessage.companion.user(prompt: "后续追问内容 follow-up")
        let noUsageAssistant = UIMessage.companion.assistant(prompt: "无 usage 的普通回复")

        let newerCompactCreatedAt = (ChatContextSnapshot.epochMillis(from: localDateTime(second: 30)) ?? 1_000) + 1_000
        let compact = IOSConversationCompact(
            id: "compact-1",
            conversationId: "conv-1",
            summary: "Compacted summary handoff",
            level: 1,
            sourceStartIndex: 0,
            sourceEndIndex: 1,
            sourceMessageIds: [String(describing: oldUser.id), String(describing: assistantWithTool.id)],
            tokenEstimate: 128,
            createdAt: newerCompactCreatedAt,
            updatedAt: newerCompactCreatedAt,
            status: "completed"
        )

        let scenarios: [(name: String, messages: [UIMessage], compacts: [IOSConversationCompact], overhead: String)] = [
            ("no-usage", [oldUser, noUsageAssistant, tailUser], [], "You are Amber.\nFollow rules."),
            ("fresh-usage-with-tool-and-tail", [oldUser, assistantWithTool, tailUser], [], "System prompt"),
            ("stale-usage-after-compact", [oldUser, assistantWithTool, tailUser], [compact], "System + Soul overhead")
        ]
        let drafts: [(text: String, extra: Int)] = [
            ("", 0),
            ("a", 0),
            ("Hello world!", 0),
            ("你好，测试上下文环增量草稿估算。", 0),
            ("", 4_500),
            ("附加图片和文件草稿", 9_321),
            ("negative extra clamped", -500)
        ]

        for scenario in scenarios {
            let base = IOSContextCompactionCoordinator.nextTurnBaseOccupancyTokens(
                messages: scenario.messages,
                activeCompacts: scenario.compacts,
                systemOverheadText: scenario.overhead
            )
            for draft in drafts {
                let monolithic = IOSContextCompactionCoordinator.nextTurnOccupancyTokens(
                    messages: scenario.messages,
                    activeCompacts: scenario.compacts,
                    draftText: draft.text,
                    extraWeightedChars: draft.extra,
                    systemOverheadText: scenario.overhead
                )
                let split = base + IOSContextCompactionCoordinator.estimateDraftTokens(
                    text: draft.text,
                    extraWeightedChars: draft.extra
                )
                XCTAssertEqual(
                    split,
                    monolithic,
                    "Mismatch in scenario \(scenario.name) for draft '\(draft.text)' extra=\(draft.extra)"
                )
            }
        }
    }

    func testChatViewModelContextSnapshotOccupancyTracksDraftAndInvalidatesBaseCache() {
        let suite = "Wave3A4OccupancyVM-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacySettings = SettingsStore(userDefaults: defaults, storageKey: "legacy-settings")
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let viewModel = ChatViewModel(settingsStore: legacySettings, sharedSettings: sharedSettings)

        let userMessage = UIMessage.companion.user(prompt: "请总结一下当前的上下文占用计算逻辑。")
        let assistantMessage = makeAssistantMessage(
            text: "已收到。",
            promptTokens: 3_200,
            completionTokens: 150,
            second: 15
        )
        viewModel.messages = [userMessage, assistantMessage]
        viewModel.tokenRevision = 1

        func expectedOccupancy(extra: Int = 0) -> Int {
            let systemPrompt = sharedSettings.snapshot.getCurrentAssistant().systemPrompt
            let soul = ChatRuntimeContextBuilder.resolvedSoulMarkdown(
                sharedSettings: sharedSettings,
                soulStore: viewModel.agentSoulStore
            )
            let overhead = [systemPrompt, soul]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return IOSContextCompactionCoordinator.shared.nextTurnOccupancyTokens(
                messages: viewModel.messages,
                conversationId: viewModel.currentConversationId,
                draftText: viewModel.inputText,
                extraWeightedChars: extra,
                systemOverheadText: overhead
            )
        }

        // First call populates base cache.
        viewModel.inputText = ""
        let initialTokens = viewModel.contextSnapshot.currentContextTokens
        XCTAssertEqual(initialTokens, expectedOccupancy())

        // Keystroke updates keep base cached and add only draft tokens.
        for draft in ["你", "你好", "你好，这是一段越来越长的测试输入草稿用于校验增量计算。"] {
            viewModel.inputText = draft
            XCTAssertEqual(
                viewModel.contextSnapshot.currentContextTokens,
                expectedOccupancy(),
                "Draft '\(draft)' must match full occupancy calculation"
            )
        }
        XCTAssertGreaterThan(viewModel.contextSnapshot.currentContextTokens, initialTokens)

        // Adding a selected file changes extraWeightedChars without changing base key.
        viewModel.pendingSelectedFilePreview = SelectedDocumentReadResult(
            fileName: "notes.txt",
            fileType: "text/plain",
            totalBytes: 2_048,
            bytesRead: 2_048,
            characterCount: 1_600,
            preview: "preview",
            isTruncated: false,
            note: nil
        )
        XCTAssertEqual(viewModel.contextSnapshot.currentContextTokens, expectedOccupancy(extra: 1_600))
        viewModel.pendingSelectedFilePreview = nil

        // Appending a message & bumping tokenRevision invalidates the base cache.
        let followUp = UIMessage.companion.user(prompt: String(repeating: "追问内容", count: 40))
        viewModel.messages.append(followUp)
        viewModel.tokenRevision += 1
        XCTAssertEqual(viewModel.contextSnapshot.currentContextTokens, expectedOccupancy())
        XCTAssertGreaterThan(
            viewModel.contextSnapshot.currentContextTokens,
            initialTokens + IOSContextCompactionCoordinator.estimateDraftTokens(
                text: viewModel.inputText,
                extraWeightedChars: 0
            )
        )
    }

    // MARK: - Astra D: Upload Preparation Zero-Overhead Short-Circuit (systemUpdates == false)

    func testUploadPreparationShortCircuitWhenSystemUpdatesFalsePreservesSequenceAndCoalescing() async throws {
        let user1 = F.userMessage("第一条用户消息")
        let assistant1 = F.assistantText("第一条助手回复")
        let user2 = F.userMessage("第二条用户消息")
        let harness = makeHarness(seedMessages: [user1, assistant1, user2])

        let capabilities = PromptTranscriptCapabilities.companion.resolve(
            setting: harness.providerSetting,
            model: harness.params.model
        )
        XCTAssertFalse(capabilities.systemUpdates, "Fixture OpenAI Chat Completions provider must resolve systemUpdates == false")

        let injectedSystemA = UIMessage.companion.system(prompt: "Runtime section A")
        let injectedSystemB = UIMessage.companion.system(prompt: "Runtime section B")
        var capturedRuntimePrepared: [UIMessage]?
        harness.bindings.messagesByInjectingRuntimeContextForRun = { messages, _, _, _ in
            [injectedSystemA, injectedSystemB] + messages
        }
        harness.bindings.prepareImageAttachments = { messages, _, _, _ in
            capturedRuntimePrepared = messages
            return messages
        }

        var capturedUpload: [UIMessage]?
        let preparation = ChatRunUploadPreparation(
            runId: "astra-d-seq",
            conversationId: harness.conversationId,
            settings: harness.dependencies.sharedSettings.snapshot,
            toolExposureBridge: harness.toolExposureBridge,
            mcpEnabled: { false },
            bindings: harness.bindings,
            isCurrentRun: { true },
            onPreparedUpload: { _, _, uploadMessages in
                capturedUpload = uploadMessages
            }
        )

        let prepared = try await preparation.prepareUploadMessages(
            harness.messages,
            provider: harness.providerSetting,
            params: harness.params
        )

        let uploaded = try XCTUnwrap(capturedUpload)
        let runtimePrepared = try XCTUnwrap(capturedRuntimePrepared)
        XCTAssertEqual(prepared.map(\.id), uploaded.map(\.id))

        let legacyOverhead = max(
            IOSContextCompactionCoordinator.estimatedTokensForRequest(runtimePrepared)
                - IOSContextCompactionCoordinator.estimatedTokensForRequest(runtimePrepared),
            0
        )
        XCTAssertEqual(legacyOverhead, 0)
        let expectedFinalized = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
            runtimePrepared,
            settings: harness.dependencies.sharedSettings.snapshot,
            params: harness.params.replacingTools(harness.toolExposureBridge.visibleTools()),
            additionalOverheadTokens: legacyOverhead
        )
        let expectedCoalesced = ChatRuntimeContextBuilder.coalescingSystemMessages(expectedFinalized)

        XCTAssertEqual(prepared.count, expectedCoalesced.count)
        XCTAssertEqual(prepared.map(\.role), expectedCoalesced.map(\.role))
        XCTAssertEqual(prepared.map { $0.toText() }, expectedCoalesced.map { $0.toText() })
        XCTAssertEqual(prepared.first?.role, MessageRole.system)
        XCTAssertTrue(prepared.first?.toText().contains("Runtime section A") == true)
        XCTAssertTrue(prepared.first?.toText().contains("Runtime section B") == true)
    }

    func testUploadPreparationShortCircuitWhenSystemUpdatesFalsePreservesCompactionBudgetFit() async throws {
        // Keep history <= 3 messages so planForceCompaction never attempts a remote
        // summarizer call, while history + default runtime prompts exceed the 18,000-token
        // window and force deterministic local budget fitting in prepare & finalize.
        let older1 = F.userMessage("历史消息一：" + String(repeating: "a", count: 24_000))
        let older2 = F.assistantText("历史回复一：" + String(repeating: "b", count: 24_000))
        let latest = F.userMessage("最后一条短问题")
        let harness = makeHarness(seedMessages: [older1, older2, latest])

        let constrainedModel = Model(
            modelId: "tight-window-model",
            displayName: "Tight Window Model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [Modality.text],
            outputModalities: [Modality.text],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 18_000),
            providerOverwrite: nil
        )
        let constrainedParams = TextGenerationParams(
            model: constrainedModel,
            temperature: harness.params.temperature,
            topP: harness.params.topP,
            maxTokens: harness.params.maxTokens,
            tools: [],
            reasoningLevel: harness.params.reasoningLevel,
            customHeaders: [],
            customBody: []
        )
        XCTAssertFalse(
            PromptTranscriptCapabilities.companion.resolve(
                setting: harness.providerSetting,
                model: constrainedModel
            ).systemUpdates
        )

        let compactSettings = harness.dependencies.sharedSettings.snapshot
        let runtimeSystem = UIMessage.companion.system(prompt: "Compact system directive")
        var capturedRuntimePrepared: [UIMessage]?
        harness.bindings.messagesByInjectingRuntimeContextForRun = { messages, _, _, _ in
            [runtimeSystem] + messages
        }
        harness.bindings.prepareImageAttachments = { messages, _, _, _ in
            capturedRuntimePrepared = messages
            return messages
        }

        let preparation = ChatRunUploadPreparation(
            runId: "astra-d-fit",
            conversationId: harness.conversationId,
            settings: compactSettings,
            toolExposureBridge: harness.toolExposureBridge,
            mcpEnabled: { false },
            bindings: harness.bindings,
            isCurrentRun: { true },
            onPreparedUpload: { _, _, _ in }
        )

        let prepared = try await preparation.prepareUploadMessages(
            harness.messages,
            provider: harness.providerSetting,
            params: constrainedParams
        )

        let runtimePrepared = try XCTUnwrap(capturedRuntimePrepared)
        let expectedFinalized = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
            runtimePrepared,
            settings: compactSettings,
            params: constrainedParams.replacingTools(harness.toolExposureBridge.visibleTools()),
            additionalOverheadTokens: 0
        )
        let expectedCoalesced = ChatRuntimeContextBuilder.coalescingSystemMessages(expectedFinalized)

        // Latest user message survives budget fitting, older history is trimmed,
        // and the final sequence matches the un-short-circuited reference strictly.
        XCTAssertTrue(prepared.contains { $0.toText() == latest.toText() })
        XCTAssertFalse(prepared.contains { $0.toText() == older1.toText() })
        XCTAssertEqual(prepared.map(\.role), expectedCoalesced.map(\.role))
        XCTAssertEqual(prepared.map { $0.toText() }, expectedCoalesced.map { $0.toText() })
    }

    // MARK: - Astra E: Wiki Notes Single-Pass Paths Equivalence

    func testWikiNotesPathsMatchesLegacyScanForAliasesEmptyTailAndStableOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wave3A4Wiki-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let notes = IOSMemoryWikiNotes(directory: root)

        // 1. Renamed topic with non-empty final revision keeps all historical alias paths.
        let t9v1 = try notes.edit(path: "topics/9-old-slug.md", content: "v1", expectedRevision: "", reason: "init")
        let t9v2 = try notes.edit(path: "topics/9-new-slug.md", content: "v2", expectedRevision: t9v1.id, reason: "rename")
        _ = try notes.edit(path: "topics/9-latest-slug.md", content: "v3", expectedRevision: t9v2.id, reason: "rename again")

        // 2. Renamed topic whose latest revision is emptied hides all alias paths.
        let t12v1 = try notes.edit(path: "topics/12-alpha.md", content: "temp note", expectedRevision: "", reason: "init")
        _ = try notes.edit(path: "topics/12-beta.md", content: "", expectedRevision: t12v1.id, reason: "clear")

        // 3. Regular note cleared then restored reappears.
        let nAv1 = try notes.edit(path: "notes/a.md", content: "first", expectedRevision: "", reason: "init")
        let nAv2 = try notes.edit(path: "notes/a.md", content: "", expectedRevision: nAv1.id, reason: "clear")
        _ = try notes.edit(path: "notes/a.md", content: "restored", expectedRevision: nAv2.id, reason: "restore")

        // 4. Regular note created empty stays hidden.
        _ = try notes.edit(path: "notes/empty.md", content: "", expectedRevision: "", reason: "empty")

        // 5. Additional paths to verify deterministic lexicographical sorting.
        _ = try notes.edit(path: "notes/z.md", content: "tail", expectedRevision: "", reason: "init")
        _ = try notes.edit(path: "index.md", content: "index note", expectedRevision: "", reason: "init")
        _ = try notes.edit(path: "topics/2-brief.md", content: "brief", expectedRevision: "", reason: "init")

        let expected = [
            "index.md",
            "notes/a.md",
            "notes/z.md",
            "topics/2-brief.md",
            "topics/9-latest-slug.md",
            "topics/9-new-slug.md",
            "topics/9-old-slug.md"
        ]
        XCTAssertEqual(notes.paths, expected)

        // Verify exact match after reloading from disk and against reference O(P * R) logic.
        let reloaded = IOSMemoryWikiNotes(directory: root)
        XCTAssertEqual(reloaded.paths, expected)

        let rawData = try Data(contentsOf: root.appendingPathComponent("wiki-notes.json"))
        let decoded = try JSONDecoder().decode([IOSMemoryWikiRevision].self, from: rawData)
        let referencePaths = Array(Set(decoded.map(\.path)))
            .filter { !(reloaded.current(path: $0)?.content.isEmpty ?? true) }
            .sorted()
        XCTAssertEqual(reloaded.paths, referencePaths)
    }

    func testWikiNotesPathsMatchesReferenceOnLargeRevisionHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wave3A4WikiLarge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var revisions: [IOSMemoryWikiRevision] = []
        var seq = 0
        for topicId in 1...40 {
            for step in 0..<8 {
                seq += 1
                let slug = step % 2 == 0 ? "old" : "new"
                let content = (topicId % 5 == 0 && step == 7) ? "" : "content-\(topicId)-\(step)"
                revisions.append(IOSMemoryWikiRevision(
                    id: "rev-\(seq)",
                    path: "topics/\(topicId)-\(slug).md",
                    content: content,
                    reason: "step \(step)",
                    source: "test",
                    restoredFrom: nil,
                    createdAt: Int64(seq)
                ))
            }
        }
        for noteIdx in 1...20 {
            seq += 1
            revisions.append(IOSMemoryWikiRevision(
                id: "rev-\(seq)",
                path: "notes/note-\(noteIdx).md",
                content: noteIdx % 3 == 0 ? "" : "body-\(noteIdx)",
                reason: "init",
                source: "test",
                restoredFrom: nil,
                createdAt: Int64(seq)
            ))
        }
        try JSONEncoder().encode(revisions).write(to: root.appendingPathComponent("wiki-notes.json"))

        let notes = IOSMemoryWikiNotes(directory: root)
        let reference = Array(Set(revisions.map(\.path)))
            .filter { !(notes.current(path: $0)?.content.isEmpty ?? true) }
            .sorted()
        XCTAssertEqual(notes.paths, reference)
    }

    // MARK: - Astra F: WebMount PNG 24-Byte Header Slice Validation

    func testWebMountVisionReaderPNGValidationAndNonZeroStartIndexSlice() async throws {
        let validPNG = try XCTUnwrap(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        // 1. Valid PNG (startIndex == 0)
        XCTAssertTrue(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: validPNG, width: 1, height: 1, format: "png")
        ))
        XCTAssertTrue(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: validPNG, width: 1, height: 1, format: " PNG ")
        ))

        // 2. Truncated headers (< 24 bytes)
        for truncatedLength in [0, 7, 8, 16, 23] {
            XCTAssertFalse(IOSWebMountVisionReader.isPNG(
                IOSWebMountScreenshotCapture(
                    data: validPNG.prefix(truncatedLength),
                    width: 1,
                    height: 1,
                    format: "png"
                )
            ))
        }

        // 3. Corrupted IHDR chunk type and mismatched dimensions
        var badChunk = validPNG
        badChunk[12] = UInt8(ascii: "X")
        XCTAssertFalse(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: badChunk, width: 1, height: 1, format: "png")
        ))
        XCTAssertFalse(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: validPNG, width: 2, height: 1, format: "png")
        ))
        XCTAssertFalse(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: validPNG, width: 1, height: 2, format: "png")
        ))
        XCTAssertFalse(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: validPNG, width: -1, height: 1, format: "png")
        ))

        // 4. Non-zero startIndex Data slice validates without out-of-bounds crash
        //    and forwards exact original bytes into the vision request.
        let prefixBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42, 0x99])
        let padded = prefixBytes + validPNG
        let sliced = padded.dropFirst(prefixBytes.count)
        XCTAssertEqual(sliced.startIndex, prefixBytes.count)
        XCTAssertEqual(sliced.count, validPNG.count)

        let slicedCapture = IOSWebMountScreenshotCapture(data: sliced, width: 1, height: 1, format: "png")
        XCTAssertTrue(IOSWebMountVisionReader.isPNG(slicedCapture))

        // Non-zero startIndex truncated slice must safely return false.
        let truncatedSlice = padded.dropFirst(prefixBytes.count).prefix(23)
        XCTAssertEqual(truncatedSlice.startIndex, prefixBytes.count)
        XCTAssertFalse(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: truncatedSlice, width: 1, height: 1, format: "png")
        ))

        // End-to-end read() with non-zero startIndex slice preserves exact base64 payload.
        let provider = VisionCaptureProvider(result: "切片截图可读。")
        let reader = IOSWebMountVisionReader(textProvider: provider)
        let answer = try await reader.read(
            capture: slicedCapture,
            question: "页面显示了什么？",
            settings: makeVisionSettings()
        )
        XCTAssertEqual(answer, "切片截图可读。")
        let imagePart = try XCTUnwrap(
            provider.messages?.last?.parts.compactMap { $0 as? UIMessagePart.Image }.first
        )
        XCTAssertEqual(imagePart.url, "data:image/png;base64,\(validPNG.base64EncodedString())")

        // 5. Large payload (~4 MiB) with non-zero startIndex slice validates cleanly.
        var largeBuffer = Data(repeating: 0xAA, count: 16)
        largeBuffer.append(validPNG)
        largeBuffer.append(Data(repeating: 0x00, count: 4 * 1024 * 1024))
        let largeSlice = largeBuffer.dropFirst(16)
        XCTAssertEqual(largeSlice.startIndex, 16)
        XCTAssertTrue(IOSWebMountVisionReader.isPNG(
            IOSWebMountScreenshotCapture(data: largeSlice, width: 1, height: 1, format: "png")
        ))
    }

    // MARK: - Helpers

    private func makeAssistantMessage(
        text: String,
        promptTokens: Int32,
        completionTokens: Int32,
        second: Int32
    ) -> UIMessage {
        let seed = UIMessage.companion.assistant(prompt: text)
        return UIMessage(
            id: seed.id,
            role: seed.role,
            parts: seed.parts,
            annotations: seed.annotations,
            createdAt: localDateTime(second: second),
            finishedAt: localDateTime(second: second + 1),
            modelId: seed.modelId,
            usage: TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedTokens: 0,
                totalTokens: promptTokens + completionTokens,
                generationDurationMs: 1_000
            ),
            translation: seed.translation
        )
    }

    private func localDateTime(second: Int32) -> Kotlinx_datetimeLocalDateTime {
        Kotlinx_datetimeLocalDateTime(
            year: 2026,
            month: 11,
            day: 25,
            hour: 12,
            minute: 0,
            second: second,
            nanosecond: 0
        )
    }

    private func makeVisionSettings() -> Settings {
        let suite = "Wave3A4Vision-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let model = Model(
            modelId: "gpt-4o",
            displayName: "Vision Test",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [Modality.text, Modality.image],
            outputModalities: [Modality.text],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Vision Test",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://api.openai.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let added = store.addProvider(provider).models[0]
        store.setCurrentChatModelId(added.id.description())
        return store.snapshot
    }
}

private final class VisionCaptureProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let result: String
    private let lock = NSLock()
    private(set) var messages: [UIMessage]?

    init(result: String) {
        self.result = result
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        lock.withLock { self.messages = messages }
        let answer = UIMessage.companion.assistant(prompt: result)
        return MessageChunk(
            id: "wave3-a4-vision",
            model: params.model.modelId,
            choices: [UIMessageChoice(index: 0, delta: nil, message: answer, finishReason: "stop")],
            usage: nil
        )
    }
}
