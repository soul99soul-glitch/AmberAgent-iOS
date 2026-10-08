import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryExtractionTests: XCTestCase {
    func testQueuedUserMemorySurvivesRestartAndKeepsConcurrentManualRecord() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            let answer = UIMessage.companion.assistant(prompt: "模型虚构的偏好不能存进记忆")
            _ = await f.store.saveCurrent(messages: [user, answer])
            let sourceId = try XCTUnwrap(f.store.currentConversation?.id)
            let provider = StubProvider { prompt, modelId in
                XCTAssertTrue(prompt.contains("我习惯用中文交流。"))
                XCTAssertFalse(prompt.contains("模型虚构的偏好不能存进记忆"))
                XCTAssertEqual(modelId, "memory-test")
                let before = IosMemoryFactory.shared.snapshotRecords()
                _ = IosMemoryFactory.shared.addMemory(scope: .core, kind: .note, content: "并发手动记录", assistantId: "__global__")
                XCTAssertTrue(f.persistence.persist(previousRecords: before))
                await f.store.newConversation()
                return Self.output(content: "我习惯用中文交流。", source: user, duplicate: true)
            }
            let queued = f.coordinator(provider: provider, environment: { (false, true, false) })
            queued.enqueue(conversationId: sourceId, baseline: [user], completed: [user, answer])
            await queued.processPending()
            XCTAssertEqual(queued.pendingCount, 1)

            let restored = f.coordinator(provider: provider)
            XCTAssertEqual(restored.pendingCount, 1)
            await restored.processPending()
            XCTAssertEqual(restored.pendingCount, 0)
            XCTAssertNotEqual(f.store.currentConversation?.id, sourceId)
            let reloaded = IOSMemoryPersistence(fileURL: f.memoryURL)
            reloaded.load()
            XCTAssertEqual(Set(reloaded.records.map(\.content)), ["并发手动记录", "我习惯用中文交流。"])
            let memory = try XCTUnwrap(reloaded.records.first { $0.kind == .user })
            XCTAssertEqual(memory.sourceConversationId, sourceId.toHexDashString())
            XCTAssertEqual(memory.sourceMessageIds, [user.id.toHexDashString()])
            XCTAssertEqual(f.audit.records.first?.status, "auto_saved")
            XCTAssertFalse(IOSSharedSettingsStore(userDefaults: f.defaults).agentRuntime.memoryWorker.runOnlyOnCharging)
        }
    }

    func testPollutionDuringModelCallPreventsAutomaticWrite() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            var calls = 0
            let provider = StubProvider { _, _ in
                calls += 1
                let marked = await f.store.markConversationMemoryPolluted(id)
                XCTAssertTrue(marked)
                return Self.output(content: "我习惯用中文交流。", source: user)
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertTrue(coordinator.statusMessage.contains("来源会话已变化"))
            await coordinator.processPending()
            XCTAssertEqual(calls, 1, "已污染的会话不能再次进入模型提炼")
            XCTAssertEqual(coordinator.pendingCount, 0)
        }
    }

    func testChargingAndPermissionGatesThenRejectsUngroundedOutput() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            f.settings.setMemoryExtractionSettings(runOnlyOnCharging: true)
            var charging = false
            var writable = true
            var calls = 0
            let provider = StubProvider { _, _ in
                calls += 1
                return Self.output(content: "模型猜测的偏好", source: user)
            }
            let coordinator = f.coordinator(provider: provider, environment: { (true, true, charging) }, writable: { writable })
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(coordinator.statusMessage.contains("等待充电"))
            charging = true
            writable = false
            await coordinator.processPending()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(coordinator.statusMessage.contains("权限已关闭"))
            writable = true
            await coordinator.processPending()
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertEqual(f.audit.records.first?.status, "failed")
            XCTAssertTrue(coordinator.statusMessage.contains("用户原文校验"))
            await coordinator.processPending()
            XCTAssertEqual(calls, 1, "失败后等待明确重试，不循环消耗模型")
        }
    }

    // MARK: 知识更新场景
    // 更新不再原地覆盖：旧版本归档保留历史，新版本通过 supersedesIds 指回旧版本，
    // 继承 scope/kind/置顶，主题成员随之指向新版本；召回只看到新版本。
    func testUpdateSupersedesOldVersionAndKeepsHistory() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我后来改成只喝冰美式了。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let existing = Self.seed("喜欢热美式。", kind: .routine, pinned: true)
            let sibling = Self.seed("早上喝咖啡。", kind: .routine)
            let topic = try XCTUnwrap(IosMemoryFactory.shared.upsertTopicRecord(
                title: "咖啡", summary: "咖啡习惯", memberIds: [existing.id, sibling.id].map { KotlinInt(value: $0) }
            ))
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { prompt, _ in
                XCTAssertTrue(prompt.contains("existing_memories"))
                XCTAssertTrue(prompt.contains("\"id\":\(Int(existing.id))"))
                return Self.memories([Self.item("update", "我后来改成只喝冰美式了。", source: user, target: Int(existing.id))])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            let old = try XCTUnwrap(records.first { $0.id == existing.id })
            XCTAssertTrue(old.archived, "旧版本归档保留，不再原地覆盖")
            XCTAssertEqual(old.content, "喜欢热美式。")
            let current = try XCTUnwrap(records.first { $0.content == "我后来改成只喝冰美式了。" })
            XCTAssertNotEqual(current.id, existing.id)
            XCTAssertFalse(current.archived)
            XCTAssertEqual(current.supersedesIds.map { Int(truncating: $0) }, [Int(existing.id)])
            XCTAssertEqual(current.scope, .longTerm)
            XCTAssertEqual(current.kind, .routine)
            XCTAssertTrue(current.pinned)
            XCTAssertEqual(current.sourceConversationId, id.toHexDashString())
            XCTAssertEqual(current.sourceMessageIds, [user.id.toHexDashString()])
            XCTAssertEqual(
                Set(records.first { $0.id == topic.id }?.memberIds.map { Int32(truncating: $0) } ?? []),
                [current.id, sibling.id]
            )
            let recall = ChatMemoryContextBuilder.contextPromptResult(records: records, runtime: nil, queryText: "冰美式")
            XCTAssertTrue(recall.ids.contains(current.id))
            XCTAssertFalse(recall.ids.contains(existing.id))
            XCTAssertEqual(f.audit.records.first?.action, "edit")
            XCTAssertEqual(f.audit.records.first?.status, "auto_saved")
            XCTAssertEqual(f.audit.records.first?.memoryId, Int(current.id))
            XCTAssertTrue(coordinator.statusMessage.contains("更新 1 条"))
        }
    }

    // 用户明确否定一条已有记忆且没有替代事实时作废（归档）它；置顶与核心记忆
    // 是用户刻意维护的，自动提炼不得作废。作废不会把否定句另存为新记忆。
    func testInvalidateArchivesContradictedMemoryButNeverPinnedOrCore() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我已经不吃素了。花生过敏那条是误会。之前说的称呼也不用了。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let vegetarian = Self.seed("我吃素。", kind: .user)
            let peanut = Self.seed("我对花生过敏。", kind: .user, pinned: true)
            let nickname = Self.seed("叫我阿琥。", kind: .user, scope: .core)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { _, _ in
                Self.memories([
                    // 无关的过期日期不影响作废（有效期只约束写入内容的操作）。
                    Self.item("invalidate", "我已经不吃素了。", source: user, target: Int(vegetarian.id),
                              expiresOn: "2000-01-01"),
                    Self.item("invalidate", "花生过敏那条是误会。", source: user, target: Int(peanut.id)),
                    Self.item("invalidate", "之前说的称呼也不用了。", source: user, target: Int(nickname.id)),
                ])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.count, 3, "作废不新增条目")
            XCTAssertEqual(records.first { $0.id == vegetarian.id }?.archived, true)
            XCTAssertEqual(records.first { $0.id == peanut.id }?.archived, false)
            XCTAssertEqual(records.first { $0.id == nickname.id }?.archived, false)
            XCTAssertEqual(f.audit.records.first?.action, "invalidate")
            XCTAssertEqual(f.audit.records.first?.memoryId, Int(vegetarian.id))
            XCTAssertTrue(coordinator.statusMessage.contains("作废 1 条"), coordinator.statusMessage)
        }
    }

    // 用户复述已有记忆是"仍然成立"的强化信号：记 lastReinforcedAt，不新增重复条目，
    // 不改正文与 updatedAt（后者是审批 CAS 令牌）。
    func testConfirmAndVerbatimRestatementReinforceWithoutDuplicating() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。周末还是会去爬山。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let language = Self.seed("我习惯用中文交流。", kind: .user)
            let hiking = Self.seed("周末通常去爬山。", kind: .routine, scope: .shortTerm)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { _, _ in
                Self.memories([
                    Self.item("add", "我习惯用中文交流。", source: user),
                    Self.item("confirm", "周末还是会去爬山。", source: user, target: Int(hiking.id),
                              scope: "short_term", kind: "routine"),
                ])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.count, 2, "复述不产生重复条目")
            for seeded in [language, hiking] {
                let stored = try XCTUnwrap(records.first { $0.id == seeded.id })
                XCTAssertNotNil(stored.lastReinforcedAt, "\(seeded.content) 应被强化")
                XCTAssertEqual(stored.content, seeded.content)
                XCTAssertEqual(stored.updatedAt, seeded.updatedAt)
            }
            XCTAssertTrue(f.audit.records.isEmpty, "强化只是使用元数据，不进写入审计")
            XCTAssertTrue(coordinator.statusMessage.contains("确认 2 条"), coordinator.statusMessage)
        }
    }

    // invalidate/confirm 不需要 scope/kind/sensitive；模型省略这些字段时不能让整批解码失败。
    func testTargetedActionsDecodeWithoutAddOnlyFields() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我已经不吃素了。周末还是会去爬山。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let vegetarian = Self.seed("我吃素。", kind: .user)
            let hiking = Self.seed("周末通常去爬山。", kind: .routine)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let source = user.id.toHexDashString()
            let provider = StubProvider { _, _ in
                """
                {"memories":[
                {"action":"invalidate","updateMemoryId":\(vegetarian.id),"content":"我已经不吃素了。","sourceMessageId":"\(source)"},
                {"action":"confirm","updateMemoryId":\(hiking.id),"content":"周末还是会去爬山。","sourceMessageId":"\(source)"}
                ]}
                """
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.first { $0.id == vegetarian.id }?.archived, true, coordinator.statusMessage)
            XCTAssertNotNil(records.first { $0.id == hiking.id }?.lastReinforcedAt)
            XCTAssertEqual(coordinator.pendingCount, 0)
        }
    }

    // 边界：与目标逐字相同的 update 只是复述 → 确认；未知 action 不得被当成 add；
    // 空串 expiresOn 视为没有有效期。
    func testIdenticalUpdateConfirmsUnknownActionSkipsBlankExpiryIgnored() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我每天跑步。我在学日语。我喜欢安静的咖啡馆。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let running = Self.seed("我每天跑步。", kind: .routine)
            let japanese = Self.seed("在学法语。", kind: .user)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { _, _ in
                Self.memories([
                    Self.item("update", "我每天跑步。", source: user, target: Int(running.id)),
                    Self.item("delete", "我在学日语。", source: user, target: Int(japanese.id)),
                    Self.item("add", "我喜欢安静的咖啡馆。", source: user, expiresOn: ""),
                ])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.count, 3, "只新增咖啡馆一条")
            let runningNow = try XCTUnwrap(records.first { $0.id == running.id })
            XCTAssertFalse(runningNow.archived, "逐字相同的 update 不产生新版本")
            XCTAssertNotNil(runningNow.lastReinforcedAt)
            XCTAssertEqual(records.first { $0.id == japanese.id }?.archived, false)
            XCTAssertFalse(records.contains { $0.content == "我在学日语。" }, "未知 action 不得写入")
            let cafe = try XCTUnwrap(records.first { $0.content == "我喜欢安静的咖啡馆。" })
            XCTAssertNil(cafe.expiresAt)
        }
    }

    // 已过期但尚未被整理归档的记录不能"吞掉"用户的再次陈述。
    func testRestatingExpiredButUnarchivedFactAddsFreshMemory() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "下周去大阪。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let expired = IosMemoryFactory.shared.addDetailedMemory(
                scope: .shortTerm, kind: .project, content: "下周去大阪。",
                assistantId: IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID,
                sourceConversationId: nil, sourceMessageIds: [], supersedesIds: [],
                expiresAt: KotlinLong(value: nowMs - 3_600_000), confidence: 1, pinned: false, archived: false
            )
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { _, _ in
                Self.memories([Self.item("add", "下周去大阪。", source: user, scope: "short_term", kind: "project")])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.contains { $0.id != expired.id && $0.content == "下周去大阪。" && $0.expiresAt == nil })
        }
    }

    // MARK: 有证据的改写场景
    // content 可改写成脱离对话也能看懂的陈述，但 evidence 必须是用户原文；
    // 助手上下文只用来理解指代，出现在助手话里的内容不能充当证据。
    func testRewrittenContentNeedsVerbatimUserEvidenceAndSeesAssistantContext() async throws {
        try await withFixture { f in
            let assistant = UIMessage.companion.assistant(prompt: "方案一用 Core Data，方案二用 SwiftData。")
            let user = UIMessage.companion.user(prompt: "就按你说的第二个方案。")
            _ = await f.store.saveCurrent(messages: [assistant, user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let provider = StubProvider { prompt, _ in
                XCTAssertTrue(prompt.contains("assistant_context"))
                XCTAssertTrue(prompt.contains("方案二用 SwiftData"), "前一条助手消息用于还原指代")
                var item = Self.item("add", "用户的项目决定用 SwiftData 存储数据。", source: user,
                                     scope: "short_term", kind: "project")
                item["evidence"] = "就按你说的第二个方案。"
                return Self.memories([item])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            XCTAssertEqual(f.persistence.records.map(\.content), ["用户的项目决定用 SwiftData 存储数据。"])
        }
    }

    func testEvidenceFoundOnlyInAssistantTextIsRejected() async throws {
        try await withFixture { f in
            let assistant = UIMessage.companion.assistant(prompt: "你应该每天早上六点起床。")
            let user = UIMessage.companion.user(prompt: "好的我考虑一下。")
            _ = await f.store.saveCurrent(messages: [assistant, user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let provider = StubProvider { _, _ in
                var item = Self.item("add", "用户每天早上六点起床。", source: user, kind: "routine")
                item["evidence"] = "你应该每天早上六点起床。"
                return Self.memories([item])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertTrue(coordinator.statusMessage.contains("用户原文校验"), coordinator.statusMessage)
        }
    }

    // review 修复：目标失效的 confirm 不能因缺 scope 让整批失败、队列停摆；
    // update 未声明 sensitive:false 不写入新版本。
    func testStaleTargetConfirmIsDroppedAndUndeclaredSensitiveUpdateIsNotWritten() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "周末还是会去爬山。我改成每天早上跑步了。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let running = Self.seed("我每天晚上跑步。", kind: .routine)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let source = user.id.toHexDashString()
            let provider = StubProvider { _, _ in
                """
                {"memories":[
                {"action":"confirm","updateMemoryId":999999,"content":"周末还是会去爬山。","sourceMessageId":"\(source)"},
                {"action":"update","updateMemoryId":\(running.id),"content":"我改成每天早上跑步了。","sourceMessageId":"\(source)"}
                ]}
                """
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            XCTAssertEqual(coordinator.pendingCount, 0, coordinator.statusMessage)
            XCTAssertFalse(coordinator.statusMessage.contains("失败"), coordinator.statusMessage)
            XCTAssertEqual(f.persistence.records.map(\.content), ["我每天晚上跑步。"])
            XCTAssertEqual(f.persistence.records.first?.archived, false)
        }
    }

    // 改写防线：证据过短（"好的"）或改写引入了原文与助手上下文里都没有的数字/英文词时丢弃；
    // 由相对时间换算出的日期允许出现。
    func testRewriteGroundingRejectsThinEvidenceAndUnsupportedTokens() {
        XCTAssertFalse(IOSMemoryExtractionCoordinator.isGrounded(
            content: "用户同意每天六点起床。", evidence: "好的", context: "你每天六点起床吧"))
        XCTAssertFalse(IOSMemoryExtractionCoordinator.isGrounded(
            content: "用户的项目改用 Kotlin 开发。", evidence: "项目换个语言吧", context: "可以考虑 Swift"))
        XCTAssertTrue(IOSMemoryExtractionCoordinator.isGrounded(
            content: "用户的项目决定用 SwiftData 存储数据。", evidence: "就按你说的第二个方案。",
            context: "方案一用 Core Data，方案二用 SwiftData。"))
        XCTAssertTrue(IOSMemoryExtractionCoordinator.isGrounded(
            content: "用户 2026-10-08（10月8日）去东京出差。", evidence: "我下周三去东京出差。", context: nil))
        XCTAssertFalse(IOSMemoryExtractionCoordinator.isGrounded(
            content: "用户下周三去东京出差，预算 5000 元。", evidence: "我下周三去东京出差。", context: nil))
    }

    // MARK: 时间感知场景
    // 有时效的事实带 expiresOn（按发言日期换算的绝对日期）；已过期或无法解析的
    // 日期说明模型没算对，宁可不存也不能存成永久记忆。
    func testTimeBoundFactStoresExpiryAndDropsExpiredOrInvalidDates() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我下周三要去东京出差。上周的会已经开完了。月底前要交报告。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let calendar = Calendar.current
            let future = calendar.date(byAdding: .day, value: 8, to: Date())!
            let past = calendar.date(byAdding: .day, value: -1, to: Date())!
            let provider = StubProvider { _, _ in
                Self.memories([
                    Self.item("add", "我下周三要去东京出差。", source: user, scope: "short_term", kind: "project",
                              expiresOn: Self.dayString(future)),
                    Self.item("add", "上周的会已经开完了。", source: user, scope: "short_term", kind: "project",
                              expiresOn: Self.dayString(past)),
                    Self.item("add", "月底前要交报告。", source: user, scope: "short_term", kind: "project",
                              expiresOn: "月底"),
                ])
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.map(\.content), ["我下周三要去东京出差。"])
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: future))!
            XCTAssertEqual(records.first?.expiresAt?.int64Value, Int64(endOfDay.timeIntervalSince1970 * 1_000),
                           "有效期截至 expiresOn 当天结束")
        }
    }

    func testExtractionPromptCarriesTodayMessageDatesAndRecordedDates() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我下周要搬家。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            _ = Self.seed("住在杭州。", kind: .user)
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let today = Self.dayString(Date())
            let provider = StubProvider { prompt, _ in
                XCTAssertTrue(prompt.contains("today: \(today)"), prompt)
                XCTAssertTrue(prompt.contains("\"\(user.id.toHexDashString())\":\"\(today)\""), prompt)
                XCTAssertTrue(prompt.contains("\"recordedOn\":\"\(today)\""), prompt)
                return #"{"memories":[]}"#
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertEqual(coordinator.pendingCount, 0)
        }
    }

    func testStaleUpdateTargetFallsBackToAdd() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我后来改成只喝冰美式了。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let prior = IosMemoryFactory.shared.snapshotRecords()
            let existing = IosMemoryFactory.shared.addDetailedMemory(
                scope: .longTerm, kind: .routine, content: "喜欢热美式。",
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
                sourceConversationId: nil, sourceMessageIds: [], supersedesIds: [],
                expiresAt: nil, confidence: 1, pinned: false, archived: false
            )
            XCTAssertTrue(f.persistence.persist(previousRecords: prior))
            let provider = StubProvider { _, _ in
                // 模型调用期间目标被并发修改：updatedAt 变化使 CAS 失败。
                _ = IosMemoryFactory.shared.updateContent(id: existing.id, content: "喜欢热美式，少糖。")
                return Self.update(content: "我后来改成只喝冰美式了。", target: Int(existing.id), source: user)
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            let records = f.persistence.records
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.first(where: { $0.id == existing.id })?.content, "喜欢热美式，少糖。")
            XCTAssertTrue(records.contains { $0.content == "我后来改成只喝冰美式了。" && $0.id != existing.id })
        }
    }

    func testHallucinatedUpdateTargetFallsBackToAdd() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            let provider = StubProvider { _, _ in
                Self.update(content: "我习惯用中文交流。", target: 999_999, source: user)
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()

            XCTAssertEqual(f.persistence.records.map(\.content), ["我习惯用中文交流。"])
            XCTAssertEqual(f.audit.records.first?.action, "create")
        }
    }

    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let settings: IOSSharedSettingsStore
        let store: IOSConversationStore
        let persistence: IOSMemoryPersistence
        let audit: IOSMemoryWriteAuditStore
        let memoryURL: URL

        func coordinator(
            provider: any IOSAgentTextProvider,
            environment: @escaping () -> (foreground: Bool, idle: Bool, charging: Bool) = { (true, true, true) },
            writable: @escaping () -> Bool = { true }
        ) -> IOSMemoryExtractionCoordinator {
            let coordinator = IOSMemoryExtractionCoordinator(
                defaults: defaults, persistence: persistence, audit: audit, provider: provider, environment: environment
            )
            coordinator.configure(settings: settings, conversations: store, writesEnabled: writable)
            return coordinator
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryExtraction-\(UUID().uuidString)")
        let suite = "MemoryExtraction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            IosMemoryFactory.shared.replaceAll(records: original)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let memoryURL = root.appendingPathComponent("memories/memories.json")
        let persistence = IOSMemoryPersistence(fileURL: memoryURL)
        persistence.load()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        let store = IOSConversationStore(baseDirectory: root.appendingPathComponent("conversations"))
        await store.bootstrap()
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let model = Model(
            modelId: "memory-test", displayName: "记忆测试", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        _ = settings.addProvider(ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "记忆测试", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "test", baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic
        ))
        settings.setCompressModelId(model.id.toHexDashString())
        settings.setMemoryRuntimeEnabled(core: true, shortTerm: true, longTerm: true)
        settings.setMemoryExtractionSettings(enabled: true, runOnlyOnCharging: false)
        try await body(Fixture(defaults: defaults, settings: settings, store: store, persistence: persistence,
                               audit: IOSMemoryWriteAuditStore(userDefaults: defaults), memoryURL: memoryURL))
    }

    private static func seed(
        _ content: String, kind: MemoryKind, scope: MemoryScope = .longTerm, pinned: Bool = false
    ) -> MemoryRecord {
        IosMemoryFactory.shared.addDetailedMemory(
            scope: scope, kind: kind, content: content,
            assistantId: scope == .core ? IosMemoryFactory.shared.GLOBAL_MEMORY_ID
                : scope == .shortTerm ? IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID
                : IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
            sourceConversationId: nil, sourceMessageIds: [], supersedesIds: [],
            expiresAt: nil, confidence: 1, pinned: pinned, archived: false
        )
    }

    private static func item(
        _ action: String, _ content: String, source: UIMessage, target: Int? = nil,
        scope: String = "long_term", kind: String = "user", expiresOn: String? = nil
    ) -> [String: Any] {
        var item: [String: Any] = ["action": action, "content": content, "scope": scope, "kind": kind,
                                   "sourceMessageId": source.id.toHexDashString(), "sensitive": false]
        if let target { item["updateMemoryId"] = target }
        if let expiresOn { item["expiresOn"] = expiresOn }
        return item
    }

    private static func memories(_ items: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["memories": items])
        return String(decoding: data, as: UTF8.self)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func update(content: String, target: Int, source: UIMessage) -> String {
        let item: [String: Any] = ["action": "update", "updateMemoryId": target, "content": content,
                                   "scope": "long_term", "kind": "user",
                                   "sourceMessageId": source.id.toHexDashString(), "sensitive": false]
        let data = try! JSONSerialization.data(withJSONObject: ["memories": [item]])
        return String(decoding: data, as: UTF8.self)
    }

    private static func output(content: String, source: UIMessage, duplicate: Bool = false) -> String {
        let item: [String: Any] = ["content": content, "scope": "long_term", "kind": "user",
                                   "sourceMessageId": source.id.toHexDashString(), "sensitive": false]
        let data = try! JSONSerialization.data(withJSONObject: ["memories": duplicate ? [item, item] : [item]])
        return String(decoding: data, as: UTF8.self)
    }

    private final class StubProvider: IOSAgentTextProvider, @unchecked Sendable {
        let response: @MainActor (String, String) async throws -> String
        init(_ response: @escaping @MainActor (String, String) async throws -> String) { self.response = response }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            let text = try await response(messages.map { $0.toText() }.joined(), params.model.modelId)
            return MessageChunk(id: "memory-test", model: "memory-test", choices: [
                UIMessageChoice(index: 0, delta: nil, message: UIMessage.companion.assistant(prompt: text), finishReason: "stop")
            ], usage: nil)
        }
    }
}
