import XCTest
import SwiftUI
@testable import iosApp

@MainActor
final class AmberIntentInboxTests: XCTestCase {

    func testExtractCandidatesClassifiesKindRefinesTitleAndFlagsApprovalRisk() {
        let researchAndWatchInput = "今天先把主线需求过一遍，对了，回头得摸一下海外潜在客户公开联系方式的底；另外顺便留意下下周国内油价调价窗口。"
        let candidates = AmberIntentCandidateExtractor.extractCandidates(
            from: researchAndWatchInput,
            conversationId: "conv-1",
            sourceMessageId: "msg-1"
        )

        XCTAssertEqual(candidates.count, 2)

        let research = candidates[0]
        XCTAssertEqual(research.title, "摸排海外潜在客户公开联系方式")
        XCTAssertEqual(research.suggestedKind, .backgroundResearch)
        XCTAssertEqual(research.riskLevel, .low)
        XCTAssertEqual(research.status, .pending)
        XCTAssertTrue(research.suggestedPrompt.contains("摸排海外潜在客户公开联系方式"))

        let watch = candidates[1]
        XCTAssertEqual(watch.title, "跟进下周国内油价调价窗口")
        XCTAssertEqual(watch.suggestedKind, .scheduledWatch)
        XCTAssertEqual(watch.riskLevel, .low)
        XCTAssertEqual(watch.suggestedKind.primaryActionTitle, "设为盯梢")

        // 涉及外发邮件 / 修改配置 / 支付等高风险副作用必须标记为 .requiresApproval，且 Jev 不可将其降级为 .low
        let highRiskInput = "晚点得整理一份季度复盘草稿，回头帮我给全体客户群发邮件通知续费并修改线上配置。"
        let riskCandidates = AmberIntentCandidateExtractor.extractCandidates(
            from: highRiskInput,
            conversationId: "conv-1",
            sourceMessageId: "msg-2"
        )
        XCTAssertEqual(riskCandidates.count, 2)
        XCTAssertEqual(riskCandidates[0].suggestedKind, .actionTodo)
        XCTAssertEqual(riskCandidates[0].riskLevel, .low)

        let highRisk = riskCandidates[1]
        XCTAssertEqual(highRisk.riskLevel, .requiresApproval)
        XCTAssertEqual(highRisk.riskLevel.badgeTitle, "需人工确认")
        XCTAssertTrue(highRisk.suggestedPrompt.contains("高风险保护"))

        let downgradeAttemptDecision = IOSJevDecision(
            answers: [
                IOSJevAnswer(
                    id: "intent_kind",
                    type: "choice",
                    noul: nil,
                    choice: AmberIntentCandidate.Kind.actionTodo.rawValue,
                    confidence: 0.92,
                    score: nil,
                    box: nil
                ),
                IOSJevAnswer(
                    id: "requires_approval",
                    type: "noul",
                    noul: 0.10,
                    choice: nil,
                    confidence: nil,
                    score: nil,
                    box: nil
                ),
            ],
            usage: nil,
            modelVersion: "jev-test",
            latencyMs: 12,
            requestBytes: 128,
            responseBytes: 64
        )
        let merged = AmberIntentCandidateExtractor.applyJevDecision(downgradeAttemptDecision, to: highRisk)
        XCTAssertEqual(merged?.riskLevel, AmberIntentCandidate.RiskLevel.requiresApproval, "本地已判定高风险需审批的候选不得被 Jev 降级")
    }

    func testStoreDeduplicatesByConversationAndSkipsExplicitDelegationTurns() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberIntentInboxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("inbox.json")

        let store = AmberIntentInboxStore(userDefaults: nil, fileURL: fileURL)

        // 1. 当轮若已显式触发 spawn_agent 或 wake_schedule，严禁重复生成随口候选
        let skipped = store.captureFromUserMessage(
            "有空帮我看看竞品定价策略",
            conversationId: "conv-a",
            sourceMessageId: "m-explicit",
            triggeredToolNames: ["spawn_agent"]
        )
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertTrue(store.pendingCandidates.isEmpty)

        // 2. 正常闲聊随口提及：成功捕捉入库
        let firstCapture = store.captureFromUserMessage(
            "有空帮我看看海外主流竞品定价策略吧！",
            conversationId: "conv-a",
            sourceMessageId: "m-1"
        )
        XCTAssertEqual(firstCapture.count, 1)
        XCTAssertEqual(store.pendingCandidates.count, 1)

        // 3. 同一会话内重复发送相同原话或产生相同意图标题（仅标点/语气差异）：自动去重
        let duplicateCapture = store.captureFromUserMessage(
            "对了，有空帮我看看海外主流竞品定价策略",
            conversationId: "conv-a",
            sourceMessageId: "m-2"
        )
        XCTAssertTrue(duplicateCapture.isEmpty)
        XCTAssertEqual(store.pendingCandidates.count, 1)

        // 4. 不同会话允许各自独立保留待办
        let otherConversationCapture = store.captureFromUserMessage(
            "有空帮我看看海外主流竞品定价策略",
            conversationId: "conv-b",
            sourceMessageId: "m-3"
        )
        XCTAssertEqual(otherConversationCapture.count, 1)
        XCTAssertEqual(store.pendingCandidates(forConversationId: "conv-a").count, 1)
        XCTAssertEqual(store.pendingCandidates(forConversationId: "conv-b").count, 1)
    }

    func testAcceptDismissClearDismissedAndPersistenceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberIntentInboxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("inbox.json")

        let store = AmberIntentInboxStore(userDefaults: nil, fileURL: fileURL)
        let added = store.captureFromUserMessage(
            "回头得查下欧洲市场合规要求；顺便留意下下周国内油价调价窗口。",
            conversationId: "conv-main",
            sourceMessageId: "msg-10"
        )
        XCTAssertEqual(added.count, 2)

        let firstId = added[0].id
        let secondId = added[1].id

        // 确认交办第一条：状态转为 .accepted 并返回完整派发载荷
        let payload = store.accept(id: firstId)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.candidateId, firstId)
        XCTAssertEqual(payload?.kind, .backgroundResearch)
        XCTAssertEqual(store.candidates.first(where: { $0.id == firstId })?.status, .accepted)
        XCTAssertEqual(store.pendingCandidates.map(\.id), [secondId])

        // 忽略第二条：状态转为 .dismissed，待确认列表清空
        XCTAssertTrue(store.dismiss(id: secondId))
        XCTAssertTrue(store.pendingCandidates.isEmpty)
        XCTAssertEqual(store.candidates.first(where: { $0.id == secondId })?.status, .dismissed)

        // 重新从磁盘加载，验证持久化一致
        let reloadedStore = AmberIntentInboxStore(userDefaults: nil, fileURL: fileURL)
        XCTAssertEqual(reloadedStore.candidates.count, 2)
        XCTAssertEqual(reloadedStore.candidates.first(where: { $0.id == firstId })?.status, .accepted)
        XCTAssertEqual(reloadedStore.candidates.first(where: { $0.id == secondId })?.status, .dismissed)

        // 清理已忽略项：仅移除 .dismissed，保留 .accepted
        reloadedStore.clearDismissed()
        XCTAssertEqual(reloadedStore.candidates.map(\.id), [firstId])

        // 验证收件箱视图可正常构造
        let sectionView = AmberIntentInboxSectionView(
            store: reloadedStore,
            conversationId: "conv-main",
            hidesWhenEmpty: false
        )
        XCTAssertNotNil(sectionView.body)
    }
}
