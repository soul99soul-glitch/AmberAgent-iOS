import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatEpisodeTests: XCTestCase {

    func testManualNewEpisodeSealingAndEmptyBoundaryIdempotency() async throws {
        try await withFixture { f in
            let vm = ChatViewModel(
                settingsStore: SettingsStore(
                    userDefaults: f.defaults,
                    storageKey: "episode-test-settings-\(UUID().uuidString)"
                ),
                sharedSettings: f.settings,
                autoGenerateResponses: false
            )
            vm.conversationStore = f.conversationStore
            vm.reloadFromStore()
            let convKey = try XCTUnwrap(vm.currentConversationId?.toHexDashString())
            defer { ChatEpisodeStore.shared.remove(conversationIds: [convKey]) }

            // Empty conversation: tapping `✦ 新话题` is a no-op (no orphan divider).
            XCTAssertFalse(vm.startNewEpisode(nowMillis: 1_700_000_000_000))
            XCTAssertTrue(ChatEpisodeStore.shared.episodes(for: convKey).isEmpty)
            XCTAssertTrue(vm.contextCompactBoundaries.isEmpty)

            // Add 2 turns of Topic A.
            let u1 = UIMessage.companion.user(prompt: "帮我核算 Santiago 临时抚养费方案，目前每月 8,508 美元。")
            let a1 = UIMessage.companion.assistant(prompt: "已记录：基础临时抚养费 8,508/月，需核对教育与医疗追加项。")
            let u2 = UIMessage.companion.user(prompt: "对方申请追加课外费，我们重点准备收入反证。")
            let a2 = UIMessage.companion.assistant(prompt: "结论：优先整理近 6 个月银行流水与税表作为反证材料。")
            vm.messages = [u1, a1, u2, a2]
            _ = await f.conversationStore.saveCurrent(messages: vm.messages)

            // First `✦ 新话题` seals Topic A into `ep_0001` and projects one lightweight divider.
            XCTAssertTrue(vm.startNewEpisode(nowMillis: 1_700_000_120_000))
            let episodes = ChatEpisodeStore.shared.episodes(for: convKey)
            XCTAssertEqual(episodes.count, 1)
            XCTAssertEqual(episodes[0].id, "ep_0001")
            XCTAssertEqual(episodes[0].turnCount, 2)
            XCTAssertEqual(episodes[0].sealReason, .manualNewTopic)
            XCTAssertEqual(episodes[0].afterMessageId, a2.id.toHexDashString())

            let episodeMarkers = vm.contextCompactBoundaries.filter(\.isEpisodeBoundary)
            XCTAssertEqual(episodeMarkers.count, 1)
            XCTAssertEqual(episodeMarkers[0].afterMessageId, a2.id.toHexDashString())
            XCTAssertEqual(episodeMarkers[0].state.customCompletedTitle, "✦ 新话题 · 前序重点已归档")
            // Continuous scroll timeline retains all historical messages.
            XCTAssertEqual(vm.messages.count, 4)

            // Immediate second tap on `✦ 新话题` while at empty boundary MUST be idempotent.
            XCTAssertFalse(vm.startNewEpisode(nowMillis: 1_700_000_125_000))
            XCTAssertEqual(ChatEpisodeStore.shared.episodes(for: convKey).count, 1)
            XCTAssertEqual(vm.contextCompactBoundaries.filter(\.isEpisodeBoundary).count, 1)
        }
    }

    func testSingleStreamConversationTitleUpdatesAcrossTurnsAndEpisodes() async throws {
        try await withFixture { f in
            var capturedTitlePrompts: [String] = []
            let auxProvider = EpisodeStubProvider { prompt in
                if prompt.contains("icon:") || prompt.contains("summarize the conversation") {
                    capturedTitlePrompts.append(prompt)
                    if prompt.contains("看鞋底这么个动作") {
                        return "看鞋底防滑出行\nicon:sparkles"
                    }
                    if prompt.contains("西湖散步") {
                        return "西湖散步带伞\nicon:map"
                    }
                    return "毒舌吐槽用户\nicon:chat"
                }
                return "建议1"
            }

            let vm = ChatViewModel(
                settingsStore: SettingsStore(
                    userDefaults: f.defaults,
                    storageKey: "episode-title-settings-\(UUID().uuidString)"
                ),
                sharedSettings: f.settings,
                autoGenerateResponses: false,
                auxiliaryTextProvider: auxProvider
            )
            vm.conversationStore = f.conversationStore
            vm.reloadFromStore()
            let convId = try XCTUnwrap(vm.currentConversationId)
            let convKey = convId.toHexDashString()
            defer { ChatEpisodeStore.shared.remove(conversationIds: [convKey]) }

            // Turn 1: initial persona / roast topic -> title becomes "毒舌吐槽用户"
            let u1 = UIMessage.companion.user(prompt: "给我来个毒舌吐槽用户的风格")
            let a1 = UIMessage.companion.assistant(prompt: "行，那我就不客气了。")
            vm.messages = [u1, a1]
            await f.conversationStore.saveCurrent(messages: vm.messages)
            vm.onGenerationCompleted(state: vm.currentRun.state)

            let deadline1 = Date().addingTimeInterval(2.0)
            while f.conversationStore.currentConversation?.title != "毒舌吐槽用户", Date() < deadline1 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(f.conversationStore.currentConversation?.title, "毒舌吐槽用户")

            // Turn 2 & Turn 3 in the same single-stream conversation shift topic to checking shoe soles
            let u2 = UIMessage.companion.user(prompt: "外面刚下完雨，路面看着有点滑")
            let a2 = UIMessage.companion.assistant(prompt: "出门前先翻过来看一眼鞋底花纹深不深。")
            let u3 = UIMessage.companion.user(prompt: "我刚看了一下鞋底，前掌还有纹路")
            let a3 = UIMessage.companion.assistant(prompt: "宝宝，这就对了。看鞋底这么个动作，比听天气预报都实在，纹路清楚就行。")
            vm.messages = [u1, a1, u2, a2, u3, a3]
            await f.conversationStore.saveCurrent(messages: vm.messages)
            vm.onGenerationCompleted(state: vm.currentRun.state)

            let deadline2 = Date().addingTimeInterval(2.0)
            while f.conversationStore.currentConversation?.title != "看鞋底防滑出行", Date() < deadline2 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(
                f.conversationStore.currentConversation?.title,
                "看鞋底防滑出行",
                "单流对话后续轮次话题演进后应刷新会话标题，不应永久卡在首轮的「毒舌吐槽用户」"
            )

            // Seal current episode and start a new Episode topic: archived messages must not leak into title prompt
            XCTAssertTrue(vm.startNewEpisode(nowMillis: 1_700_000_200_000))
            let u4 = UIMessage.companion.user(prompt: "周末去西湖散步带什么伞比较好？")
            let a4 = UIMessage.companion.assistant(prompt: "带一把轻便的晴雨两用折叠伞就够了。")
            vm.messages = [u1, a1, u2, a2, u3, a3, u4, a4]
            await f.conversationStore.saveCurrent(messages: vm.messages)
            vm.onGenerationCompleted(state: vm.currentRun.state)

            let deadline3 = Date().addingTimeInterval(2.0)
            while f.conversationStore.currentConversation?.title != "西湖散步带伞", Date() < deadline3 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(f.conversationStore.currentConversation?.title, "西湖散步带伞")
            let latestTitlePrompt = try XCTUnwrap(capturedTitlePrompts.last)
            XCTAssertTrue(latestTitlePrompt.contains("西湖散步"))
            XCTAssertFalse(
                latestTitlePrompt.contains("看鞋底这么个动作"),
                "新 Episode 的标题生成输入不应混入已归档 Episode 的旧消息"
            )
        }
    }

    func testAutomaticThreeHourIdleGapSealsPriorEpisodeBeforeNewMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeIdle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let episodeStore = ChatEpisodeStore(baseDirectoryURL: tempDir)
        let convId = UUID().uuidString.lowercased()

        let u1 = UIMessage.companion.user(prompt: "早上好，看下今天 iOS 构建包体积。")
        let a1 = UIMessage.companion.assistant(prompt: "当前 IPA 体积 48.2 MB，符号表正常。")
        let baseMillis: Int64 = 1_730_678_400_000 // 08:00:00
        episodeStore.recordMessageTimestamp(conversationId: convId, messageId: u1.id.toHexDashString(), timestampMillis: baseMillis)
        episodeStore.recordMessageTimestamp(conversationId: convId, messageId: a1.id.toHexDashString(), timestampMillis: baseMillis + 60_000)

        // +2 hours (7,200s <= 10,800s): must NOT split.
        let twoHoursLater = baseMillis + 60_000 + (2 * 3_600 * 1_000)
        XCTAssertNil(
            episodeStore.sealIfIdleTimeoutExceeded(
                conversationId: convId,
                existingMessages: [u1, a1],
                incomingMessageTimestampMillis: twoHoursLater
            )
        )
        XCTAssertTrue(episodeStore.episodes(for: convId).isEmpty)

        // +3 hours + 2 seconds (> 10,800s): MUST automatically seal `[u1, a1]` into `ep_0001`.
        let overThreeHours = baseMillis + 60_000 + Int64((ChatEpisodeConstants.idleTimeoutSeconds + 2) * 1_000)
        let sealed = try XCTUnwrap(
            episodeStore.sealIfIdleTimeoutExceeded(
                conversationId: convId,
                existingMessages: [u1, a1],
                incomingMessageTimestampMillis: overThreeHours
            )
        )
        XCTAssertEqual(sealed.id, "ep_0001")
        XCTAssertEqual(sealed.sealReason, .idleTimeout)
        XCTAssertEqual(sealed.afterMessageId, a1.id.toHexDashString())

        // Persistence round-trip check.
        await episodeStore.flushPendingWritesForTesting()
        let reloadedStore = ChatEpisodeStore(baseDirectoryURL: tempDir)
        XCTAssertEqual(reloadedStore.episodes(for: convId).map(\.id), ["ep_0001"])
    }

    func testActiveEpisodeWindowFiltersLLMUploadMessagesWithoutDroppingTimeline() async throws {
        try await withFixture { f in
            let conversationId = try XCTUnwrap(f.conversationStore.currentConversation?.id)
            let convKey = conversationId.toHexDashString()
            defer { ChatEpisodeStore.shared.remove(conversationIds: [convKey]) }

            let oldU1 = UIMessage.companion.user(prompt: "旧话题：东京五天四晚机酒预算 12,000 元。")
            let oldA1 = UIMessage.companion.assistant(prompt: "旧回复：建议住新宿附近，机票约 3,800 元。")
            _ = ChatEpisodeStore.shared.sealCurrentEpisodeIfNeeded(
                conversationId: convKey,
                messages: [oldU1, oldA1],
                reason: .manualNewTopic,
                nowMillis: 1_730_680_000_000
            )

            // Right after sealing, occupancy of empty active window excludes archived messages.
            let emptyWindowOccupancy = IOSContextCompactionCoordinator.shared.nextTurnOccupancyTokens(
                messages: [oldU1, oldA1],
                conversationId: conversationId,
                draftText: ""
            )
            XCTAssertEqual(emptyWindowOccupancy, 0)

            // New topic message arrives in the same visual stream.
            let newU2 = UIMessage.companion.user(prompt: "新话题：帮我写一段 Swift Actor 死锁排查清单。")
            let systemMsg = UIMessage.companion.system(prompt: "System base prompt")
            let fullStream = [systemMsg, oldU1, oldA1, newU2]

            let prepared = try await IOSContextCompactionCoordinator.shared.prepareMessagesForRequest(
                uploadMessages: fullStream,
                conversationId: conversationId,
                settings: f.settings.snapshot,
                params: TextGenerationParams(
                    model: f.model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
                    reasoningLevel: .off, customHeaders: [], customBody: []
                ),
                fallbackProvider: f.providerSetting
            )

            let preparedIds = prepared.map { $0.id.toHexDashString() }
            XCTAssertTrue(preparedIds.contains(systemMsg.id.toHexDashString()))
            XCTAssertTrue(preparedIds.contains(newU2.id.toHexDashString()))
            XCTAssertFalse(preparedIds.contains(oldU1.id.toHexDashString()), "Archived Episode user turn must not leak into active LLM window")
            XCTAssertFalse(preparedIds.contains(oldA1.id.toHexDashString()), "Archived Episode assistant turn must not leak into active LLM window")
        }
    }

    func testRecentEpisodesIndexCapsAtEightItemsAndThreeHundredTokensAndRecallToolWorks() async throws {
        try await withFixture { f in
            let conversationId = try XCTUnwrap(f.conversationStore.currentConversation?.id)
            let convKey = conversationId.toHexDashString()
            let tempEpisodeDir = f.root.appendingPathComponent("episodes", isDirectory: true)
            let episodeStore = ChatEpisodeStore(baseDirectoryURL: tempEpisodeDir)

            var allMessages: [UIMessage] = []
            for idx in 1...11 {
                let u = UIMessage.companion.user(
                    prompt: idx == 2
                        ? "讨论 Santiago 抚养费争点：临时抚养费每月 8,508 美元，如何应对追加费用？"
                        : "第 \(idx) 个话题：服务器集群扩容预算 \(idx * 1_250) 元与监控告警阈值校准方案细节。"
                )
                let a = UIMessage.companion.assistant(
                    prompt: idx == 2
                        ? "建议提交真实税表反证，控制在 8,508/月基线内，驳回非必要追加项。"
                        : "已确认第 \(idx) 批节点采用双活部署，P99 延迟目标控制在 \(100 + idx)ms 以内。"
                )
                allMessages.append(contentsOf: [u, a])
                _ = episodeStore.sealCurrentEpisodeIfNeeded(
                    conversationId: convKey,
                    messages: allMessages,
                    reason: .manualNewTopic,
                    nowMillis: 1_730_680_000_000 + Int64(idx * 600_000)
                )
            }
            _ = await f.conversationStore.saveCurrent(messages: allMessages)

            let allSealed = episodeStore.episodes(for: convKey)
            XCTAssertEqual(allSealed.count, 11)

            // Resident Recent Episodes Index: strictly latest 8 (`ep_0004` ... `ep_0011`) and `<= 300` tokens.
            let indexPrompt = ChatEpisodeContextSupport.recentEpisodesPrompt(
                conversationId: convKey,
                isOrchestratedChild: false,
                store: episodeStore
            )
            XCTAssertFalse(indexPrompt.contains("ep_0001"))
            XCTAssertFalse(indexPrompt.contains("ep_0003"))
            XCTAssertTrue(indexPrompt.contains("ep_0004"))
            XCTAssertTrue(indexPrompt.contains("ep_0011"))
            let tokens = ChatEpisodeContextSupport.estimatedTokens(for: indexPrompt)
            XCTAssertLessThanOrEqual(tokens, ChatEpisodeConstants.maxRecentEpisodesIndexTokens, "Index tokens (\(tokens)) exceeded 300 limit")

            // Orchestrated child worker receives empty index (strict worker isolation).
            XCTAssertEqual(
                ChatEpisodeContextSupport.recentEpisodesPrompt(
                    conversationId: convKey,
                    isOrchestratedChild: true,
                    store: episodeStore
                ),
                ""
            )

            // Resident tool exposure & approval-free contract.
            let declaration = ChatEpisodeRecallTool.declaration
            XCTAssertEqual(declaration.name, "episode_recall")
            XCTAssertFalse(declaration.needsApproval)
            XCTAssertTrue(declaration.allowsAutoApproval)
            XCTAssertFalse(declaration.mandatoryApproval)

            let vm = ChatViewModel(
                settingsStore: SettingsStore(
                    userDefaults: f.defaults,
                    storageKey: "episode-test-settings-recall-\(UUID().uuidString)"
                ),
                sharedSettings: f.settings,
                autoGenerateResponses: false
            )
            vm.conversationStore = f.conversationStore
            vm.reloadFromStore()
            XCTAssertTrue(vm.currentToolDeclarationNames().contains("episode_recall"))

            // Exact `episode_id` recall retrieves `ep_0002` even after it aged out of the 8-item index.
            let byIdRaw = await ChatEpisodeRecallTool.execute(
                arguments: #"{"episode_id":"ep_0002"}"#,
                currentConversationId: conversationId,
                conversationStore: f.conversationStore,
                episodeStore: episodeStore
            )
            let byIdObj = try XCTUnwrap(ChatToolCallParsing.jsonObject(byIdRaw))
            XCTAssertEqual(byIdObj["ok"] as? Bool, true)
            XCTAssertEqual(byIdObj["episode_id"] as? String, "ep_0002")
            let transcript = try XCTUnwrap(byIdObj["transcript"] as? String)
            XCTAssertTrue(transcript.contains("8,508"))
            XCTAssertTrue(transcript.contains("税表反证"))

            // Keyword `query` recall finds `ep_0002` by entity name.
            let byQueryRaw = await ChatEpisodeRecallTool.execute(
                arguments: #"{"query":"Santiago 8,508"}"#,
                currentConversationId: conversationId,
                conversationStore: f.conversationStore,
                episodeStore: episodeStore
            )
            let byQueryObj = try XCTUnwrap(ChatToolCallParsing.jsonObject(byQueryRaw))
            XCTAssertEqual(byQueryObj["ok"] as? Bool, true)
            XCTAssertEqual(byQueryObj["matched_episode_id"] as? String, "ep_0002")
        }
    }

    func testBackgroundDistillationRequiresTwoTurnsAndDeduplicatesOrSupersedesMemories() async throws {
        try await withFixture { f in
            let tempEpisodeDir = f.root.appendingPathComponent("episodes-distill", isDirectory: true)
            let episodeStore = ChatEpisodeStore(baseDirectoryURL: tempEpisodeDir)
            let convKey = UUID().uuidString.lowercased()

            // Seed existing memories: one preference to be reinforced, one project metric to be superseded.
            let existingPref = IosMemoryFactory.shared.addDetailedMemory(
                scope: .longTerm, kind: .feedback,
                content: "汇报方案时偏好先给核心结论，再列简要行动项",
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
                sourceConversationId: nil, sourceMessageIds: [], supersedesIds: [],
                expiresAt: nil, confidence: 1, pinned: false, archived: false
            )
            let existingMetric = IosMemoryFactory.shared.addDetailedMemory(
                scope: .longTerm, kind: .project,
                content: "Santiago 案临时抚养费暂估为每月 7,200 美元",
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
                sourceConversationId: nil, sourceMessageIds: [], supersedesIds: [],
                expiresAt: nil, confidence: 1, pinned: false, archived: false
            )
            XCTAssertTrue(f.persistence.persist(previousRecords: []))

            var modelCallCount = 0
            let stubProvider = EpisodeStubProvider { _ in
                modelCallCount += 1
                return """
                {
                  "title": "Santiago 抚养费核定",
                  "summary": "临时抚养费核定 8,508 美元/月，准备近半年税表反证追加项",
                  "memories": [
                    {"scope": "LONG_TERM", "kind": "FEEDBACK", "content": "汇报方案时偏好先给核心结论，再列简要行动项"},
                    {"scope": "LONG_TERM", "kind": "PROJECT", "content": "Santiago 案临时抚养费核定为每月 8,508 美元"},
                    {"scope": "LONG_TERM", "kind": "PROJECT", "content": "正在推进 Amber iOS 单流 Episode 上下文隔离改造"}
                  ]
                }
                """
            }
            let distiller = ChatEpisodeDistiller(
                episodeStore: episodeStore,
                memoryPersistence: f.persistence,
                auditStore: f.audit,
                textProvider: stubProvider,
                defaults: f.defaults
            )

            // 1. Short Episode (< 2 turns) skips model call & memory writes.
            let shortMessages = [
                UIMessage.companion.user(prompt: "在吗？"),
                UIMessage.companion.assistant(prompt: "在的，请说。")
            ]
            let shortEp = try XCTUnwrap(
                episodeStore.sealCurrentEpisodeIfNeeded(
                    conversationId: convKey,
                    messages: shortMessages,
                    reason: .manualNewTopic,
                    nowMillis: 1_730_680_000_000
                )
            )
            XCTAssertEqual(shortEp.turnCount, 1)
            let shortOutcome = await distiller.distill(
                episode: shortEp,
                episodeMessages: shortMessages,
                sharedSettings: f.settings
            )
            XCTAssertEqual(modelCallCount, 0)
            XCTAssertEqual(shortOutcome.totalMutated, 0)

            // 2. Substantive Episode (>= 2 turns) refines summary and deduplicates/supersedes memories.
            let substantiveMessages = [
                UIMessage.companion.user(prompt: "最新裁定出来了，Santiago 案临时抚养费定在每月 8,508 美元。"),
                UIMessage.companion.assistant(prompt: "收到，已从此前暂估的 7,200 更新为 8,508 美元/月。"),
                UIMessage.companion.user(prompt: "另外我正在推进 Amber iOS 单流 Episode 上下文隔离改造，记得结论先行。"),
                UIMessage.companion.assistant(prompt: "明白：结论先行，聚焦 Episode 隔离与防失忆目录。")
            ]
            let fullMessages = shortMessages + substantiveMessages
            let ep2 = try XCTUnwrap(
                episodeStore.sealCurrentEpisodeIfNeeded(
                    conversationId: convKey,
                    messages: fullMessages,
                    reason: .manualNewTopic,
                    nowMillis: 1_730_680_600_000
                )
            )
            XCTAssertEqual(ep2.turnCount, 2)

            let outcome = await distiller.distill(
                episode: ep2,
                episodeMessages: substantiveMessages,
                sharedSettings: f.settings,
                nowMillis: 1_730_680_610_000
            )
            XCTAssertEqual(modelCallCount, 1)
            XCTAssertEqual(outcome.reinforcedCount, 1, "Exact/near-duplicate preference should reinforce existing record")
            XCTAssertEqual(outcome.supersededCount, 1, "Updated numeric fact should supersede outdated record")
            XCTAssertEqual(outcome.addedCount, 1, "Brand new project focus should be added once")

            let updatedEp2 = try XCTUnwrap(episodeStore.episode(id: ep2.id, in: convKey))
            XCTAssertEqual(updatedEp2.title, "Santiago 抚养费核定")
            XCTAssertTrue(updatedEp2.summary.contains("8,508"))
            XCTAssertEqual(updatedEp2.distillationStatus, .completedModel)

            let activeRecords = f.persistence.records.filter { !$0.archived && $0.kind != .topic }
            XCTAssertEqual(activeRecords.count, 3, "Must remain 3 clean active records instead of 5 bloated duplicates")
            XCTAssertTrue(activeRecords.contains { $0.id == existingPref.id })
            XCTAssertFalse(activeRecords.contains { $0.id == existingMetric.id }, "Outdated 7,200 record must be archived")
            XCTAssertTrue(activeRecords.contains { $0.content.contains("8,508") })
            XCTAssertTrue(activeRecords.contains { $0.content.contains("Episode 上下文隔离") })

            // Verify 3D Embodiment portrait cache was refreshed synchronously on persist.
            let portraitData = try XCTUnwrap(f.defaults.data(forKey: "app.amber.ios.agentSoul.memoryPortrait.v1"))
            let portrait = try JSONDecoder().decode(AgentMemoryPortraitSummary.self, from: portraitData)
            XCTAssertFalse(portrait.identityAndFocus.isEmpty)
        }
    }

    // MARK: - Test Fixture

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let settings: IOSSharedSettingsStore
        let conversationStore: IOSConversationStore
        let persistence: IOSMemoryPersistence
        let audit: IOSMemoryWriteAuditStore
        let model: Model
        let providerSetting: ProviderSetting
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let originalMemories = IosMemoryFactory.shared.snapshotRecords()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatEpisodeTests-\(UUID().uuidString)")
        let suiteName = "ChatEpisodeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalMemories)
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        IosMemoryFactory.shared.replaceAll(records: [])
        let memoryURL = root.appendingPathComponent("memories/memories.json")
        let persistence = IOSMemoryPersistence(fileURL: memoryURL)
        persistence.load()

        let convDir = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        let conversationStore = IOSConversationStore(baseDirectory: convDir)
        await conversationStore.bootstrap()

        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let model = Model(
            modelId: "episode-test-model",
            displayName: "Episode Test",
            id: KotlinUuid.companion.random(),
            type: .chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: KotlinInt(value: 32_000),
            providerOverwrite: nil
        )
        let providerSetting = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Episode Test Provider",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: .apiKey,
            brand: .generic
        )
        _ = settings.addProvider(providerSetting)
        settings.setCurrentChatModelId(model.id.toHexDashString())
        settings.setCompressModelId(model.id.toHexDashString())
        settings.setMemoryRuntimeEnabled(core: true, shortTerm: true, longTerm: true)

        let fixture = Fixture(
            root: root,
            defaults: defaults,
            settings: settings,
            conversationStore: conversationStore,
            persistence: persistence,
            audit: IOSMemoryWriteAuditStore(userDefaults: defaults),
            model: model,
            providerSetting: providerSetting
        )
        try await body(fixture)
    }

    private final class EpisodeStubProvider: IOSAgentTextProvider, @unchecked Sendable {
        let handler: @MainActor (String) async throws -> String

        init(_ handler: @escaping @MainActor (String) async throws -> String) {
            self.handler = handler
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let prompt = messages.map { $0.toText() }.joined(separator: "\n")
            let output = try await handler(prompt)
            return MessageChunk(
                id: "ep-distill-chunk",
                model: params.model.modelId,
                choices: [
                    UIMessageChoice(
                        index: 0,
                        delta: nil,
                        message: UIMessage.companion.assistant(prompt: output),
                        finishReason: "stop"
                    )
                ],
                usage: nil
            )
        }
    }
}
