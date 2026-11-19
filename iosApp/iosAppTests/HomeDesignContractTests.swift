import Foundation
import Shared
import UIKit
import XCTest
@testable import iosApp

final class HomeDesignContractTests: XCTestCase {
    /// 设计硬约束：首页图标统一 Phosphor fill（路径数据与定稿原型内嵌 symbol 同源）。
    /// 每个字形必须能被解析器完整消化：非空、整体落在 256 viewBox 内（含贝塞尔控制点余量）。
    func testHomePhosphorGlyphsParse() {
        XCTAssertEqual(HomePhosphor.allCases.count, 300, "首页 Phosphor 字形表意外增删")
        for icon in HomePhosphor.allCases {
            let path = HomeSVGPathParser.parse(icon.pathData)
            let box = path.boundingRect
            XCTAssertFalse(box.isNull || box.isEmpty, "\(icon) 解析结果为空")
            // 窄长字形（如 arrowsVertical/arrowsHorizontal）短边本就不足 100；只要求长边未塌缩。
            XCTAssertGreaterThan(max(box.width, box.height), 100, "\(icon) 解析后尺寸异常：\(box)")
            XCTAssertGreaterThan(min(box.width, box.height), 0, "\(icon) 解析后塌缩为线：\(box)")
            XCTAssertLessThan(box.minX, 256, "\(icon) 越出 viewBox 右缘：\(box)")
            XCTAssertLessThan(box.minY, 256, "\(icon) 越出 viewBox 下缘：\(box)")
            XCTAssertGreaterThan(box.maxX, 0, "\(icon) 越出 viewBox 左缘：\(box)")
            XCTAssertGreaterThan(box.maxY, 0, "\(icon) 越出 viewBox 上缘：\(box)")
        }
    }

    func testIconMapperMappings() {
        let expectations = [
            ("赵光义晚年有怀念赵匡胤的记录吗", HomePhosphor.moon),
            ("今晚的红酒品鉴笔记", .wine),
            ("赵匡胤的打仗风格是什么样的？", .sword),
            ("皇帝成长计划复盘", .crown),
            ("赵匡胤在位 16 年也不短了，但是为什么", .crown),
            ("明朝十六帝的顺序。", .list),
            ("巫师三的经典 BGM 都有哪些", .musicNotes),
            ("中国各朝各代的都城都在哪", .mapPin),
            ("痛风药影响精子质量吗", .pill),
            ("秦皇汉武，唐宗宋祖，到底谁应该被排第一", .scales),
        ]

        for (title, expectedSymbol) in expectations {
            XCTAssertEqual(
                HomeConversationIcon.icon(forTitle: title, isPinned: false),
                expectedSymbol,
                "标题“\(title)”应使用语义化的实心图标 \(expectedSymbol)"
            )
        }
        XCTAssertEqual(
            HomeConversationIcon.icon(forTitle: "任何会话标题", isPinned: true),
            .pushPin,
            "置顶会话必须优先显示实心图钉"
        )
        // 无语义命中的标题统一用中性气泡，不按哈希抽取无关图标。
        let unmapped = "梁圣和牢梁的区别是什么"
        XCTAssertEqual(
            HomeConversationIcon.icon(forTitle: unmapped, isPinned: false),
            HomeConversationIcon.fallback,
            "无匹配标题必须显示中性气泡"
        )
        XCTAssertEqual(
            HomeConversationIcon.icon(forTitle: unmapped, isPinned: false, preferredKey: "crown"),
            .crown,
            "LLM preferredKey 优先于标题哈希/语义"
        )
        XCTAssertEqual(
            HomeConversationIcon.canonicalLLMKey("CROWN"),
            "crown",
            "catalog key 应规范化为小写 slug"
        )
        XCTAssertNil(
            HomeConversationIcon.canonicalLLMKey("listChecks"),
            "非 catalog 的 enum 名不应当作 LLM key"
        )
        XCTAssertEqual(HomeConversationIcon.fallback, .chatCircle, "fallback 常量仍为实心气泡")
    }

    /// Q2 性能修复：`icon(forTitle:isPinned:preferredKey:)` 加了主线程内的小缓存，
    /// 命中缓存的结果必须与未命中（首次求值）完全一致，且不同入参不能互相污染。
    func testIconLookupCacheMatchesUncachedResultAndKeysAreIndependent() {
        let titles = [
            "赵匡胤的打仗风格是什么样的？",
            "今晚的红酒品鉴笔记",
            "梁圣和牢梁的区别是什么",
        ]
        for title in titles {
            let first = HomeConversationIcon.icon(forTitle: title, isPinned: false)
            for _ in 0..<5 {
                XCTAssertEqual(
                    HomeConversationIcon.icon(forTitle: title, isPinned: false),
                    first,
                    "重复调用（命中缓存）必须与首次求值结果一致：\(title)"
                )
            }
        }
        // isPinned / preferredKey 变化必须落到不同缓存桶，不能互相污染彼此的结果。
        XCTAssertEqual(HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: true), .pushPin)
        XCTAssertNotEqual(
            HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: true),
            HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: false),
            "isPinned 不同必须命中不同缓存条目"
        )
        XCTAssertEqual(
            HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: false, preferredKey: "crown"),
            .crown
        )
        XCTAssertNotEqual(
            HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: false, preferredKey: "crown"),
            HomeConversationIcon.icon(forTitle: "同一个标题", isPinned: false, preferredKey: nil),
            "preferredKey 不同必须命中不同缓存条目"
        )
    }

    /// Q2 性能修复：`ConversationSummaryRow` 现在是 `Equatable`（供首页列表 `.equatable()`
    /// 跳过未变化行的重算）。这里验证：body 实际读取/展示的字段（title/isPinned/
    /// messageCount/updateAt 以及行自身的 isCurrent/isGenerating/listPreview/
    /// listIconKey/slice/hidesSeparator）任一变化都必须判定不相等；其余字段
    /// （assistantId/createAt/memoryMode 等本行不读的 summary 字段）不参与比较。
    @MainActor
    func testConversationSummaryRowEquatableTracksOnlyDisplayedFields() {
        func makeSummary(
            title: String,
            id: KotlinUuid,
            isPinned: Bool = false,
            messageCount: Int32 = 1,
            updateAtMs: Int64 = 0
        ) -> ConversationSummary {
            ConversationSummary(
                id: id,
                title: title,
                assistantId: KotlinUuid.companion.random(),
                createAt: KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0),
                updateAt: KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: updateAtMs),
                isPinned: isPinned,
                messageCount: messageCount,
                memoryMode: .enabled,
                hasImageGenerationTool: false
            )
        }

        func makeRow(
            _ summary: ConversationSummary,
            isCurrent: Bool = false,
            isGenerating: Bool = false,
            listPreview: String = "",
            listIconKey: String? = nil,
            slice: HomeCardSlice = .single,
            hidesSeparator: Bool = false
        ) -> ConversationSummaryRow {
            ConversationSummaryRow(
                summary: summary,
                isCurrent: isCurrent,
                isGenerating: isGenerating,
                listPreview: listPreview,
                listIconKey: listIconKey,
                slice: slice,
                hidesSeparator: hidesSeparator,
                onTap: {},
                onRename: {},
                onTogglePin: {},
                onDelete: {}
            )
        }

        let sharedId = KotlinUuid.companion.random()
        let base = makeSummary(title: "标题", id: sharedId)

        XCTAssertEqual(
            makeRow(base),
            makeRow(makeSummary(title: "标题", id: sharedId)),
            "summary 结构相同（同一 id/title/isPinned/messageCount/updateAt）且其余行属性不变时应判定相等，" +
            "让 SwiftUI 跳过这一行的重算"
        )

        XCTAssertNotEqual(
            makeRow(base),
            makeRow(makeSummary(title: "新标题", id: sharedId)),
            "标题变化必须判定不相等——否则 body 不会用新标题重算，onRename 捕获的 summary.title 也会过期"
        )
        XCTAssertNotEqual(
            makeRow(base),
            makeRow(makeSummary(title: "标题", id: sharedId, isPinned: true)),
            "置顶状态变化必须判定不相等"
        )
        XCTAssertNotEqual(
            makeRow(base),
            makeRow(makeSummary(title: "标题", id: sharedId, messageCount: 2)),
            "消息条数变化必须判定不相等"
        )
        XCTAssertNotEqual(
            makeRow(base),
            makeRow(makeSummary(title: "标题", id: sharedId, updateAtMs: 1_000)),
            "updateAt 变化（影响相对时间展示）必须判定不相等"
        )
        XCTAssertNotEqual(makeRow(base, isCurrent: true), makeRow(base, isCurrent: false), "isCurrent 变化必须判定不相等")
        XCTAssertNotEqual(makeRow(base, isGenerating: true), makeRow(base, isGenerating: false), "isGenerating 变化必须判定不相等")
        XCTAssertNotEqual(makeRow(base, listPreview: "浓缩预览"), makeRow(base, listPreview: ""), "listPreview 变化必须判定不相等")
        XCTAssertNotEqual(makeRow(base, listIconKey: "crown"), makeRow(base, listIconKey: nil), "listIconKey 变化必须判定不相等")
        XCTAssertNotEqual(makeRow(base, slice: .top), makeRow(base, slice: .bottom), "slice 变化必须判定不相等")
        XCTAssertNotEqual(
            makeRow(base, hidesSeparator: true),
            makeRow(base, hidesSeparator: false),
            "hidesSeparator 变化必须判定不相等"
        )
    }

    @MainActor
    func testParseTitleAndIcon() {
        let both = ChatViewModel.parseTitleAndIcon("宋太祖\nicon:crown")
        XCTAssertEqual(ChatViewModel.sanitizeTitle(both.title), "宋太祖")
        XCTAssertEqual(both.iconKey, "crown")

        let iconOnly = ChatViewModel.parseTitleAndIcon("icon:coffee")
        XCTAssertTrue(ChatViewModel.sanitizeTitle(iconOnly.title).isEmpty)
        XCTAssertEqual(iconOnly.iconKey, "coffee")

        let badIcon = ChatViewModel.parseTitleAndIcon("随便标题\nicon:not_a_real_key_zzz")
        XCTAssertEqual(ChatViewModel.sanitizeTitle(badIcon.title), "随便标题")
        XCTAssertNil(badIcon.iconKey)

        let cased = ChatViewModel.parseTitleAndIcon("标题\nicon:Crown")
        XCTAssertEqual(cased.iconKey, "crown")
    }

    func testContinueModelHidesWhenNoResumableWork() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertNil(
            HomeContinueCardModel.resolve(now: now),
            "没有真实待继续任务时应收起首行，避免与下方功能入口重复"
        )
    }

    func testCompletedImageResultBeatsDraftButNotRecoverableWork() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let image = HomeImageGenerationRef(
            id: "conversation|message|tool",
            conversationID: "conversation",
            messageID: "message",
            toolCallID: "tool",
            prompt: "雨夜里的未来城市",
            state: .completed,
            updatedAt: now
        )
        let completedSelected = try XCTUnwrap(HomeContinueCardModel.resolve(
            imageGeneration: image,
            now: now
        ))

        XCTAssertEqual(completedSelected.feature, .imageGeneration)
        XCTAssertEqual(completedSelected.feature.icon, .imageSquare)
        XCTAssertEqual(completedSelected.ctaTitle, "查看图片")
        XCTAssertTrue(completedSelected.meta.hasPrefix("图片已生成 · "))
        XCTAssertEqual(
            completedSelected.destination,
            .generatedImage(
                ChatMessageAnchor(
                    conversationID: "conversation",
                    messageID: "message",
                    toolCallID: "tool"
                )
            )
        )
    }

    func testImageGenerationResumeProjectionUsesOwningMessageAndRejectsFalseSuccess() throws {
        let running = imageToolMessage(
            toolCallID: "tool-running",
            prompt: "山谷",
            output: [],
            finished: false
        )
        XCTAssertNil(ChatImageGenerationResumeProjection.latest(
            in: [running],
            conversationID: "conversation-running",
            isGenerationActive: false
        ))
        let runningContext = try XCTUnwrap(ChatImageGenerationResumeProjection.latest(
            in: [running],
            conversationID: "conversation-running",
            isGenerationActive: true
        ))
        XCTAssertEqual(runningContext.state, .running)
        XCTAssertEqual(runningContext.messageID, ChatMessageProjector.messageId(for: running))

        let completed = imageToolMessage(
            toolCallID: "tool-completed",
            prompt: "雨夜里的未来城市",
            output: [UIMessagePart.Image(url: "amber-image-generation://result.png", metadata: nil)],
            finished: true
        )
        let completedContext = try XCTUnwrap(ChatImageGenerationResumeProjection.latest(
            in: [completed],
            conversationID: "conversation-completed",
            isGenerationActive: false
        ))
        XCTAssertEqual(completedContext.state, .completed)
        XCTAssertEqual(completedContext.prompt, "雨夜里的未来城市")
        XCTAssertEqual(completedContext.toolCallID, "tool-completed")
        XCTAssertEqual(completedContext.messageID, ChatMessageProjector.messageId(for: completed))

        let falseSuccess = imageToolMessage(
            toolCallID: "tool-false-success",
            prompt: "没有图片",
            output: [UIMessagePart.Text(
                text: #"{"status":"ok","source":"generate_image","files":[]}"#,
                metadata: nil
            )],
            finished: true
        )
        XCTAssertNil(ChatImageGenerationResumeProjection.latest(
            in: [falseSuccess],
            conversationID: "conversation-false-success",
            isGenerationActive: false
        ))

        let newerCompleted = ChatImageGenerationResumeContext(
            id: "completed",
            conversationID: "conversation-completed",
            messageID: "message-completed",
            toolCallID: "tool-completed",
            prompt: "已完成",
            state: .completed,
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        let olderRunning = ChatImageGenerationResumeContext(
            id: "running",
            conversationID: "conversation-running",
            messageID: "message-running",
            toolCallID: "tool-running",
            prompt: "生成中",
            state: .running,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        XCTAssertEqual(
            ChatImageGenerationResumeProjection.preferred(
                in: [newerCompleted, olderRunning]
            ),
            olderRunning,
            "运行中的生图必须高于较新的已完成结果"
        )

        let matched = try XCTUnwrap(ChatImageGenerationResumeProjection.matching(
            in: [completed],
            conversationID: "conversation-completed",
            messageID: completedContext.messageID,
            toolCallID: completedContext.toolCallID,
            isGenerationActive: false
        ))
        XCTAssertEqual(matched, completedContext)

        let suiteName = "HomeImageResume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(ChatImageGenerationResumeConsumption.markViewedIfCompleted(
            anchor: ChatMessageAnchor(
                conversationID: "conversation-running",
                messageID: runningContext.messageID,
                toolCallID: runningContext.toolCallID
            ),
            messages: [running],
            isGenerationActive: true,
            userDefaults: defaults
        ))
        XCTAssertEqual(ChatImageGenerationResumeConsumption.markViewedIfCompleted(
            anchor: ChatMessageAnchor(
                conversationID: "conversation-completed",
                messageID: completedContext.messageID,
                toolCallID: completedContext.toolCallID
            ),
            messages: [completed],
            isGenerationActive: false,
            userDefaults: defaults
        ), completedContext.id)
        XCTAssertEqual(
            defaults.string(forKey: ChatImageGenerationResumeConsumption.viewedCompletionIDKey),
            completedContext.id
        )
    }

    func testContinueModelOnlySurfacesTruthfulMiniAppAndCouncilWork() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let alreadyOpened = HomeMiniAppRef(
            id: "app-opened",
            title: "已打开应用",
            latestVersionCreatedAt: now.addingTimeInterval(-120),
            lastRunAt: now.addingTimeInterval(-60)
        )
        let newVersion = HomeMiniAppRef(
            id: "app-new-version",
            title: "财务计算器",
            latestVersionCreatedAt: now.addingTimeInterval(-30),
            lastRunAt: now.addingTimeInterval(-90)
        )
        let completedCouncil = HomeCouncilTaskRef(
            id: "council-complete",
            title: "已完成讨论",
            status: .completed,
            updatedAt: now,
            canContinue: true
        )

        let selected = try XCTUnwrap(HomeContinueCardModel.resolve(
            councilTask: completedCouncil,
            miniApps: [alreadyOpened, newVersion],
            now: now
        ))

        XCTAssertEqual(selected.destination, .miniAppRunner("app-new-version"))
        XCTAssertEqual(selected.title, "小应用")
        XCTAssertEqual(selected.ctaTitle, "打开")
        XCTAssertTrue(selected.meta.contains("新版本尚未打开"))

        XCTAssertNil(
            HomeContinueCardModel.resolve(
                councilTask: completedCouncil,
                miniApps: [alreadyOpened],
                now: now
            ),
            "已完成议会和已经运行过的最新小应用版本都不能冒充未完成任务"
        )
    }

    func testCurrentAvatarBreathIntensityMatchesPrototypeTiming() {
        // 原型：delay 1.6s，period 3.4s，ease-in-out 0 → 1 → 0
        XCTAssertEqual(HomeCurrentAvatarBreath.delaySeconds, 1.6, accuracy: 0.001)
        XCTAssertEqual(HomeCurrentAvatarBreath.periodSeconds, 3.4, accuracy: 0.001)
        XCTAssertEqual(HomeCurrentAvatarBreath.intensity(elapsed: 0, reduceMotion: false), 0, accuracy: 0.001)
        XCTAssertEqual(HomeCurrentAvatarBreath.intensity(elapsed: 1.59, reduceMotion: false), 0, accuracy: 0.001)
        XCTAssertEqual(
            HomeCurrentAvatarBreath.intensity(elapsed: 1.6 + 3.4 * 0.5, reduceMotion: false),
            1.0,
            accuracy: 0.001,
            "半周期应到峰值光晕"
        )
        XCTAssertEqual(
            HomeCurrentAvatarBreath.intensity(elapsed: 1.6 + 3.4, reduceMotion: false),
            0,
            accuracy: 0.001,
            "整周期应回到零"
        )
        XCTAssertEqual(
            HomeCurrentAvatarBreath.intensity(elapsed: 100, reduceMotion: true),
            0,
            accuracy: 0.001,
            "Reduce Motion 必须关掉呼吸（初始关键无光晕）"
        )
    }

    @MainActor
    func testListPreviewSanitizeAndWiringContracts() throws {
        XCTAssertEqual(
            ChatViewModel.sanitizeListPreview("  \"已整理好宋史相关段落，要看看吗？\"  \n第二行"),
            "已整理好宋史相关段落，要看看吗？"
        )
        let long = String(repeating: "摘要", count: 20)
        let truncated = ChatViewModel.sanitizeListPreview("- \(long)")
        XCTAssertEqual(truncated.count, 28, "浓缩预览必须限长 28")
        XCTAssertEqual(ChatViewModel.sanitizeListPreview(""), "")

        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let chatVM = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Generation/ChatAuxiliaryGeneration.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(chatVM.contains("generateConversationListPreview(state: state)"))
        XCTAssertTrue(chatVM.contains("ConversationListPreviewGenerator.schedule"))

        let generator = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/ConversationListPreviewGenerator.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(generator.contains("requestTokens"))
        XCTAssertTrue(generator.contains("titleModelId"))

        let bgExecutor = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundExecutor.swift"),
            encoding: .utf8
        )
        let bgTerminalWriter = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            bgExecutor.contains("ConversationListPreviewGenerator.schedule"),
            "后台直接成功完成必须挂 list preview，避免仅 FG generationSucceeded"
        )
        XCTAssertTrue(
            bgTerminalWriter.contains("ConversationListPreviewGenerator.schedule"),
            "后台恢复后的成功终态也必须挂 list preview"
        )

        let store = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/IOSConversationStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("listPreviewsByConversationId"))
        XCTAssertTrue(store.contains("list-previews.json"))
        XCTAssertTrue(store.contains("deletedConversationIds.contains(key)"))

        let home = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("iosApp/Home/ConversationsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(home.contains("listPreview: conversationStore.listPreview(for: summary.id)"))
        let rows = try String(
            contentsOf: testsDirectory.deletingLastPathComponent().appendingPathComponent("iosApp/Home/ConversationSummaryRow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(rows.contains("restartMetaCycleIfNeeded"))
        XCTAssertTrue(rows.contains("showingListPreview"))
        XCTAssertTrue(rows.contains("scaleAnchor: .leading"))
        XCTAssertTrue(rows.contains("duration: 0.4"))
    }

    private func imageToolMessage(
        toolCallID: String,
        prompt: String,
        output: [UIMessagePart],
        finished: Bool
    ) -> UIMessage {
        let seed = UIMessage.companion.assistant(prompt: "")
        return UIMessage(
            id: seed.id,
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallID,
                toolName: "generate_image",
                input: #"{"prompt":"\#(prompt)"}"#,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: finished ? chatNowLocalDateTime() : nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }
}
