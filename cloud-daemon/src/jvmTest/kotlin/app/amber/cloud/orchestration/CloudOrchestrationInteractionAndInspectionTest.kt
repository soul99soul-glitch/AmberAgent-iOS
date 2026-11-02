package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.ChannelKind
import app.amber.cloud.channel.InboundMessage
import app.amber.cloud.channel.SenderRole
import app.amber.cloud.runtime.ExecutionScope
import app.amber.cloud.security.PlaceholderCredentialException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.nio.charset.StandardCharsets
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CloudOrchestrationInteractionAndInspectionTest {

    // ========================================================================
    // 9. 安全与权限边界：非主人/Agent/Automation 建任务被拒、Worker 越权与横向发消息被拒、SUBAGENT 工具剥离
    // ========================================================================

    @Test
    fun security_provenance_rbac_worker_restrictions_and_subagent_tool_stripping() = runTest {
        CloudOrchestrationKernelTest.Harness().use { h ->
            val now = h.clock.get()
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-guest", "u-guest", "telegram", SenderRole.GUEST, MessageProvenanceOrigin.GUEST_HUMAN, "h1", now),
                "访客试图派发任务",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-collab", "u-collab", "feishu", SenderRole.COLLABORATOR, MessageProvenanceOrigin.COLLABORATOR_HUMAN, "h2", now),
                "群协作者试图派发任务",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-agent", "agent", "internal", SenderRole.OWNER, MessageProvenanceOrigin.AGENT, "h3", now),
                "Agent 自造消息",
            )
            h.store.recordSourceMessage(
                SourceMessageProvenance("s1", "msg-auto", "auto", "internal", SenderRole.OWNER, MessageProvenanceOrigin.AUTOMATION, "h4", now),
                "Automation 消息",
            )

            val sampleSpec = listOf(
                WorkItemSubmissionSpec("sec-1", "测试任务", "测试", ExecutionTargetNode.CloudSubagent("w"))
            )

            for (badMsgId in listOf("msg-guest", "msg-collab", "msg-agent", "msg-auto", "msg-non-existent")) {
                assertFailsWith<UnauthorizedWorkSourceException> {
                    h.kernel.submitWorkBatch(
                        principal = h.coordinatorPrincipal(),
                        requestId = "req-bad-$badMsgId",
                        contextMessageIds = listOf(badMsgId),
                        items = sampleSpec,
                    )
                }
            }

            val ownerMsg = h.recordOwnerMessage("msg-owner-ok", "主人合法授权")
            val created = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-owner-ok",
                contextMessageIds = listOf(ownerMsg),
                items = sampleSpec,
            ).items.single()
            val workerPrincipal = h.kernel.workerPrincipalFor(created)

            assertFailsWith<PrincipalPermissionException> {
                h.kernel.submitWorkBatch(
                    principal = workerPrincipal,
                    requestId = "req-by-worker",
                    contextMessageIds = listOf(ownerMsg),
                    items = listOf(WorkItemSubmissionSpec("sub-2", "越权子任务", "越权", ExecutionTargetNode.CloudSubagent("w"))),
                )
            }
            assertFailsWith<PrincipalPermissionException> {
                h.kernel.sendLateralMessage(workerPrincipal, "other-session", "私下横向通信")
            }
            assertFailsWith<PrincipalPermissionException> {
                h.kernel.steerWorker(workerPrincipal, created.workItemId, "自我重定向")
            }

            assertFailsWith<PrincipalPermissionException> {
                h.store.writeArchivedDocument(workerPrincipal, "SOUL.md", "篡改最高指令")
            }
            assertFailsWith<PrincipalPermissionException> {
                h.store.writeArchivedDocument(workerPrincipal, "inbox/other-work-id/report.md", "伪造他人报告")
            }
            assertFailsWith<PlaceholderCredentialException> {
                h.store.writeArchivedDocument(h.coordinatorPrincipal(), "docs/note.md", "包含占位符 <redacted>")
            }

            val subagentTools = h.toolRegistry.declaredTools(ExecutionScope.SUBAGENT).map { it.name }.toSet()
            assertFalse("terminal_exec" in subagentTools)
            assertFalse("ssh_profile_create" in subagentTools)
            assertFalse("workspace_file_write" in subagentTools)
            assertTrue("history_search" in subagentTools)

            val blockedExec = h.kernel.executeWorkerTool(
                principal = workerPrincipal,
                toolName = "terminal_exec",
                args = buildJsonObject { put("command", "rm -rf /") },
            ).jsonObject
            assertEquals(false, blockedExec["ok"]?.jsonPrimitive?.booleanOrNull)
        }
    }

    // ========================================================================
    // 10. 自动化三模式接入 ProactiveEngine：DEDICATED 平时静默仅完成/L3 异动发卡、32KiB/8KiB 与单轮信封
    // ========================================================================

    @Test
    fun automations_three_modes_proactive_engine_32kib_8kib_envelope_and_dedicated_silent_policy() = runTest {
        CloudOrchestrationKernelTest.Harness(withProactiveEngine = true).use { h ->
            h.kernel.registerAutomation(
                CloudAutomationSpec(
                    automationId = "auto-pr-watch",
                    title = "盯紧 PR 142 CI 状态",
                    prompt = "检查 PR 142 是否合并或出现构建失败",
                    mode = CloudAutomationMode.DEDICATED,
                    completionPolicy = CompletionPolicy(stopWhenClause = "PR 142 已合并", confidenceThreshold = 0.8),
                )
            )

            val hugeMemory = ("状态记录😀🚀：" + "琥珀云端本体持续跟踪日志条目。".repeat(20) + "\n").repeat(80)
            assertTrue(hugeMemory.toByteArray(StandardCharsets.UTF_8).size > 32 * 1024)

            var capturedEnvelope: AutomationRunEnvelope? = null
            var capturedPrincipal: CloudPrincipal.AutomationRunner? = null

            val run1 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.get()) { env, runner, _ ->
                capturedEnvelope = env
                capturedPrincipal = runner
                h.kernel.updateAutomationMemory(runner, "auto-pr-watch", hugeMemory, h.clock.get())
                AutomationTurnOutput(
                    summary = "第 1 次检查：CI 仍在排队，无异常",
                    decision = "notify",
                    l3AnomalyDetected = false,
                )
            }
            assertFalse(run1.cardPushed, "DEDICATED 模式平时巡检必须静默，不得发卡")
            assertEquals(0, h.pushedCards.size)

            val savedAfterRun1 = h.store.getAutomation("auto-pr-watch")!!
            val savedBytes = savedAfterRun1.memoryText.toByteArray(StandardCharsets.UTF_8).size
            assertTrue(savedBytes <= OrchestrationHash.AUTOMATION_MEMORY_MAX_BYTES, "持久化记忆不得超过 32 KiB: $savedBytes")
            assertNull(savedAfterRun1.activeRunId, "回合结束后必须立即收回 activeRunId")

            assertFailsWith<PrincipalPermissionException> {
                h.kernel.updateAutomationMemory(capturedPrincipal!!, "auto-pr-watch", "手动轮次越权修改")
            }

            val run2 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.addAndGet(60_000L)) { env, _, _ ->
                capturedEnvelope = env
                AutomationTurnOutput(
                    summary = "检测到 L3 级异动：PR 142 出现阻塞性编译失败",
                    l3AnomalyDetected = true,
                )
            }
            val env2 = assertNotNull(capturedEnvelope)
            val tailBytes = env2.memoryTail8KiB.toByteArray(StandardCharsets.UTF_8).size
            assertTrue(tailBytes in 1..OrchestrationHash.AUTOMATION_MEMORY_INJECT_TAIL_BYTES)
            assertFalse(Character.isLowSurrogate(env2.memoryTail8KiB.first()))
            assertTrue(run2.cardPushed, "DEDICATED 模式出现 L3 异动时必须发卡")
            assertEquals(1, h.pushedCards.size)
            assertEquals(run1.sessionId, run2.sessionId, "DEDICATED 模式必须复用同一个专属会话")

            val run3 = h.kernel.executeAutomationRun("auto-pr-watch", h.clock.addAndGet(60_000L)) { _, _, _ ->
                AutomationTurnOutput(
                    summary = "PR 142 已合并，跟踪目标达成",
                    l3AnomalyDetected = false,
                )
            }
            assertTrue(run3.disabled)
            assertEquals("completed", run3.disabledReason)
            assertTrue(run3.cardPushed)
            assertEquals(2, h.pushedCards.size)
            assertTrue(h.proactiveEngine!!.metrics().l1EvaluatedCount >= 2)

            h.kernel.registerAutomation(
                CloudAutomationSpec(
                    automationId = "auto-hb",
                    title = "主线心跳",
                    prompt = "检查待办",
                    mode = CloudAutomationMode.HEARTBEAT,
                    maxIterations = 1,
                )
            )
            h.kernel.isRouterTurnBusy = true
            val deferredHb = h.kernel.executeAutomationRun("auto-hb", h.clock.get()) { _, _, _ ->
                AutomationTurnOutput("不应执行")
            }
            assertTrue(deferredHb.deferredHeartbeat)
            assertEquals(h.clock.get() + 15_000L, deferredHb.nextRetryAtMs)
            h.kernel.isRouterTurnBusy = false
        }
    }

    // ========================================================================
    // 11. 对标 Grok bot 交互：连发 3 条消息 2 秒内确认、不暴露工具名/参数/推理、状态 started->done 原地编辑、100 词上限
    // ========================================================================

    @Test
    fun grok_bot_style_three_rapid_messages_acked_under_2s_outward_sanitized_status_edited_in_place_and_100_word_budget() = runBlocking {
        CloudOrchestrationKernelTest.Harness().use { h ->
            val sink = CloudOrchestrationKernelTest.MockEditableImSink()
            val workerContinueGate = CompletableDeferred<Unit>()
            val workerProgressReady = CompletableDeferred<Unit>()

            h.kernel.autoExecuteWorkersInBackground = true
            h.kernel.workerTurnRunner = { item, principal ->
                val current = h.store.getWorkItem(item.workItemId)!!
                h.kernel.updateWorkerProgress(
                    principal = principal,
                    workItemId = item.workItemId,
                    expectedRevision = current.progressRevision,
                    progressNote = "<thinking>内部思考</thinking>调用 terminal_exec({\"cmd\":\"ls\"}) 排查日志 sk-ant-api03-SECRETKEY1234567890ABCDEF",
                    activeToolName = "terminal_exec",
                    nowEpochMs = h.clock.addAndGet(100L),
                )
                workerProgressReady.complete(Unit)
                workerContinueGate.await()
                WorkerSettlementReport(
                    workItemId = item.workItemId,
                    outcome = "completed",
                    summary = "已完成排查，修复方案准备就绪",
                )
            }

            var dispatchedOnce = false
            val router = CloudRouter(
                kernel = h.kernel,
                sink = sink,
                brain = RouterBrain { _ ->
                    if (!dispatchedOnce) {
                        dispatchedOnce = true
                        val longWords = (1..130).joinToString(" ") { "结论要点$it" }
                        RouterDecision(
                            reply = """
                                <thinking>先调 dispatch_work 再用 workspace_file_write({"path":"/tmp/a"})</thinking>
                                我已经安排后台处理 terminal_exec 和 history_search 了，密钥是 sk-ant-api03-SECRETKEY1234567890ABCDEF
                                {"raw_param": "should_not_appear"}
                                ```json
                                {"tool": "ssh_profile_create"}
                                ```
                                $longWords
                            """.trimIndent(),
                            dispatch = listOf(
                                WorkItemSubmissionSpec(
                                    taskKey = "grok-task-1",
                                    title = "排查崩溃与执行 terminal_exec 检查",
                                    brief = "定位崩溃原因",
                                    targetNode = ExecutionTargetNode.CloudSubagent("worker"),
                                    subscribedThreadKeys = listOf("telegram:chat-grok:thread-1"),
                                )
                            ),
                        )
                    } else {
                        RouterDecision(reply = "补充指示已合并跟进。")
                    }
                },
                executionToolNames = setOf("terminal_exec", "workspace_file_write", "ssh_profile_create", "history_search"),
                clockMs = { h.clock.get() },
            )

            val ack1 = router.onInbound(
                InboundMessage(
                    messageId = "gm-1",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "帮我查一下最近三天崩溃原因",
                )
            )
            val ack2 = router.onInbound(
                InboundMessage(
                    messageId = "gm-2",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "顺便重点看网络模块",
                )
            )
            val ack3 = router.onInbound(
                InboundMessage(
                    messageId = "gm-3",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "结果简短告诉我",
                )
            )

            for (ack in listOf(ack1, ack2, ack3)) {
                assertTrue(ack.latencyMs < 2_000L, "确认延迟必须 < 2000ms，实际=${ack.latencyMs}ms")
                assertTrue(ack.text.startsWith("收到"), "确认语应为简短人话: ${ack.text}")
            }

            workerProgressReady.await()
            val interjectAck = router.onInbound(
                InboundMessage(
                    messageId = "gm-thread-interject",
                    channel = ChannelKind.TELEGRAM,
                    chatId = "chat-grok",
                    threadId = "thread-1",
                    senderId = "owner-1",
                    senderRole = SenderRole.OWNER,
                    text = "把 iOS 18 的日志也算进去",
                )
            )
            assertIs<DefaultCloudOrchestrationKernel.InboundRoutingDecision.DirectPassThroughToWorkers>(interjectAck.routing)

            workerContinueGate.complete(Unit)
            router.awaitIdle(includeWorkers = true)

            val item = h.store.listWorkItems().single()
            val statusMsgId = assertNotNull(router.statusMessageIdFor(item.workItemId))
            val statusEntry = assertNotNull(sink.entryFor(statusMsgId))

            assertTrue(statusEntry.editHistory.size >= 2, "状态消息必须在原消息上多次编辑更新: ${statusEntry.editHistory}")
            assertTrue(statusEntry.editHistory.first().startsWith("⏳"), "初始状态应为 started: ${statusEntry.editHistory.first()}")
            assertTrue(statusEntry.currentText.startsWith("✅"), "最终状态应编辑为 done: ${statusEntry.currentText}")

            val phases = router.activityLog.filter { it.taskId == item.workItemId }.map { it.phase }
            assertEquals(ActivityPhase.STARTED, phases.first())
            assertTrue(ActivityPhase.PROGRESS in phases)
            assertEquals(ActivityPhase.DONE, phases.last())
            for (act in router.activityLog) {
                val cpLen = act.label.codePointCount(0, act.label.length)
                assertTrue(cpLen <= 20, "ActivityStatus.label 必须 <= 20 字: ${act.label} ($cpLen)")
                assertFalse(act.label.contains("terminal_exec"))
                assertFalse(act.label.contains("SECRETKEY1234567890ABCDEF"))
            }

            val forbidden = listOf(
                "terminal_exec",
                "workspace_file_write",
                "ssh_profile_create",
                "history_search",
                "dispatch_work",
                "<thinking>",
                "内部思考",
                "should_not_appear",
                "SECRETKEY1234567890ABCDEF",
            )
            for (out in router.outboundLog) {
                for (bad in forbidden) {
                    assertFalse(out.contains(bad, ignoreCase = true), "对外消息严禁包含 '$bad'，实际消息: $out")
                }
                val wordCount = OrchestrationHash.countWords(out)
                assertTrue(wordCount <= 100, "单次 IM 回复不得超过 100 词，实际=$wordCount: $out")
            }
            assertTrue(router.outboundLog.any { it.contains("doc:docs/replies/") }, "超 100 词回复应自动归档并附上引用")
        }
    }

    // ========================================================================
    // 12. 双层游标无损读取、Unicode 代理对安全切片、防撕裂校验、取证诊断与链式召回
    // ========================================================================

    @Test
    fun two_layer_lossless_session_reading_unicode_surrogate_safety_diagnostics_and_chain_of_recall() = runTest {
        CloudOrchestrationKernelTest.Harness().use { h ->
            val msgId = h.recordOwnerMessage("msg-read-1", "生成带 Emoji 的长分析报告", threadKey = "feishu:group:oc_1")
            val created = h.kernel.submitWorkBatch(
                principal = h.coordinatorPrincipal(),
                requestId = "req-read-diag",
                contextMessageIds = listOf(msgId),
                items = listOf(
                    WorkItemSubmissionSpec(
                        taskKey = "read-diag-task",
                        title = "长报告与诊断测试",
                        brief = "输出包含高低代理对的长文本",
                        targetNode = ExecutionTargetNode.CloudSubagent("analyst"),
                        subscribedThreadKeys = listOf("feishu:group:oc_1"),
                    )
                ),
                nowEpochMs = h.clock.get(),
            ).items.single()
            val sessionId = created.workerSessionId!!

            val emojiBody = "段落🔥🚀😀🎉".repeat(60)
            val assistantMsg = UIMessage.assistant(emojiBody)
            h.kernel.appendWorkerMessage(sessionId, assistantMsg, h.clock.addAndGet(1_000L))

            val page = h.kernel.readWorkerSessionPage(sessionId, pageSize = 10, maxMessageChars = 80)
            assertEquals(2, page.items.size)
            val preview = page.items[1]
            assertTrue(preview.truncated)
            assertFalse(Character.isHighSurrogate(preview.previewText.last()), "预览截断绝不能劈开 UTF-16 高代理项")

            h.kernel.markMessageStreaming(preview.messageId, streaming = true, nowEpochMs = h.clock.get())
            assertFailsWith<MessageVersionMismatchException> {
                h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = preview.messageVersion,
                        offsetChars = 0,
                        limitChars = 50,
                    )
                )
            }
            h.kernel.markMessageStreaming(preview.messageId, streaming = false, nowEpochMs = preview.messageVersion.substringBefore(':').toLong())

            assertFailsWith<MessageVersionMismatchException> {
                h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = "999999:10",
                        offsetChars = 0,
                        limitChars = 50,
                    )
                )
            }

            val reconstructed = StringBuilder()
            var offset: Int? = 0
            while (offset != null) {
                val slice = h.kernel.readWorkerMessageSlice(
                    MessageSliceCursor(
                        sessionId = sessionId,
                        messageIndex = preview.messageIndex,
                        messageId = preview.messageId,
                        messageVersion = preview.messageVersion,
                        offsetChars = offset,
                        limitChars = 13,
                    )
                )
                assertFalse(Character.isLowSurrogate(slice.sliceText.first()), "切片起点不得落在低代理项上")
                assertFalse(Character.isHighSurrogate(slice.sliceText.last()), "切片终点不得停在高代理项上")
                reconstructed.append(slice.sliceText)
                offset = slice.nextOffsetChars
            }
            assertEquals(emojiBody, reconstructed.toString())

            repeat(5) { idx ->
                h.kernel.recordStreamingChunk(sessionId, preview.messageId, "chunk-$idx", h.clock.addAndGet(10L))
            }
            val diag = h.kernel.diagnoseWorkerSession(sessionId, h.clock.get())
            assertTrue(diag.recentCollapsedEvents.any { it.contains("streamUpdates: 5") })
            assertTrue(diag.coverageNote.contains("SQLite 持久化诊断表 (complete=true"))
            assertTrue(diag.coverageNote.contains("absence in ring buffer is not proof"))

            val hop1 = assertNotNull(h.kernel.recallObject(RecallObjectKind.TRIGGER_MESSAGE, msgId))
            assertTrue(hop1.nextHops.any { it.kind == RecallObjectKind.WORK_ITEM && it.id == created.workItemId })
            val hop2 = assertNotNull(h.kernel.recallObject(RecallObjectKind.WORK_ITEM, created.workItemId))
            assertTrue(hop2.nextHops.any { it.kind == RecallObjectKind.WORKER_SESSION && it.id == sessionId })
            val hop3 = assertNotNull(h.kernel.recallObject(RecallObjectKind.WORKER_SESSION, sessionId))
            assertTrue(hop3.inlineText.isNotBlank())
        }
    }
}
