package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.orchestration.RouterBrain
import app.amber.cloud.orchestration.RouterDecision
import app.amber.cloud.runtime.CloudAgentKernel
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.soul.SoulPutRequestDto
import app.amber.cloud.gateway.PairedDevice
import kotlinx.coroutines.*
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.*

class NativeDialoguePersonaFeedbackTest {
    private suspend fun fixture(model: CloudModelClient,
        block: suspend (CloudAgentKernel, PairedDevice, AtomicLong) -> Unit) {
        val dir = Files.createTempDirectory("native-feedback-policy").toFile()
        val k = CloudAgentKernel(dir, model, masterSecretOverride = "feedback-policy-fixture")
        val now = AtomicLong(0)
        k.nativeDialogue.clockMs = now::get
        k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(), "ios", "fixture")
        try { block(k, k.gatewayState.loadDevicesStrict().single(), now) }
        finally {
            k.router.awaitIdle(includeWorkers = true); k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin()
            k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close(); dir.deleteRecursively()
        }
    }

    @Test fun different_personas_supply_different_waiting_voice_without_inventing_progress() = runBlocking {
        val texts = mutableListOf<String>()
        val calls = AtomicInteger()
        fixture(CloudModelClient { messages, tools ->
            if (!messages.first().toText().contains("<native-wait-feedback>")) return@CloudModelClient UIMessage.assistant("{\"tags\":[]}")
            assertTrue(tools.isEmpty())
            assertContains(messages.first().toText(), "不编造检查、工具动作、进度、耗时或承诺")
            assertContains(messages.last().toText(), "\"acceptedTasks\":\"\"")
            assertContains(messages.last().toText(), "\"latestVisibleProgress\":\"\"")
            calls.incrementAndGet()
            UIMessage.assistant(if (messages.first().toText().contains("温和熟悉")) "我还在等这轮回应，陪你等一会儿呀。"
                else "这轮回应尚未返回，我会继续留意。")
        }) { k, device, now ->
            for ((index, style) in listOf("温和熟悉", "简练专业").withIndex()) {
                k.soulStore.put(SoulPutRequestDto(displayName = "合成角色$index", soulMarkdown = style, isDefault = false))
                val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
                k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "答复") }
                try {
                    val receipt = k.nativeDialogue.submit(device, "persona-$index", "看看这轮请求")
                    withTimeout(2_000) { started.await() }
                    now.addAndGet(1_500); k.nativeDialogue.evaluateFeedback()
                    withTimeout(2_000) { while (!k.orchestrationStore.dialogue.hasEvent("ack:${receipt.eventId}")) delay(10) }
                    texts += k.orchestrationStore.dialogue.page(0, 100).items.single { it.id == "ack:${receipt.eventId}" }.text
                } finally { release.complete(Unit); k.router.awaitIdle() }
            }
            assertEquals(2, calls.get())
            assertEquals(2, texts.distinct().size, "人格化不能只是所有角色换成同一句新模板")
            assertTrue(texts.none { it.contains("正在处理") || it.contains("收到") || it.contains("已检查") })
        }
    }

    @Test fun simple_reply_and_slow_light_wakeup_do_not_get_extra_bubbles() = runBlocking {
        val feedbackCalls = AtomicInteger()
        fixture(CloudModelClient { messages, _ ->
            if (messages.first().toText().contains("<native-wait-feedback>")) {
                assertContains(messages.first().toText(), "轻量唤醒或闲聊无需等待正文")
                feedbackCalls.incrementAndGet()
                UIMessage.assistant("<no-feedback/>")
            } else UIMessage.assistant("{\"tags\":[]}")
        }) { k, device, now ->
            k.router.brain = RouterBrain { RouterDecision(reply = "11") }
            val simple = k.nativeDialogue.submit(device, "math", "5+6")
            withTimeout(2_000) { while (k.nativeDialogue.receipt(device, "math")!!.state != "consumed") delay(10) }
            now.set(2_000); k.nativeDialogue.evaluateFeedback()
            assertEquals(listOf("11"), k.orchestrationStore.dialogue.page(0, 100).items.filter { it.topicId == simple.topicId && it.role == "assistant" }.map { it.text })
            assertEquals(0, feedbackCalls.get(), "快速答复不额外请求等待生成")
            val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "在呢。") }
            try {
                val wakeup = k.nativeDialogue.submit(device, "wakeup", "在吗")
                withTimeout(2_000) { started.await() }
                now.set(3_500); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { while (feedbackCalls.get() != 1) delay(10) }
                now.set(4_500); k.nativeDialogue.evaluateFeedback()
                assertTrue(k.orchestrationStore.dialogue.page(0, 100).items.none { it.topicId == wakeup.topicId && it.role == "assistant" })
                assertEquals("received", k.nativeDialogue.receipt(device, "wakeup")!!.state)
                assertEquals(1, feedbackCalls.get(), "空草稿不能触发每秒重新生成")
            } finally { release.complete(Unit); k.router.awaitIdle() }
        }
    }

    @Test fun unchanged_silence_never_repeats_the_previous_waiting_sentence() = runBlocking {
        val calls = AtomicInteger()
        fixture(CloudModelClient { messages, _ ->
            if (messages.first().toText().contains("<native-wait-feedback>")) {
                if (calls.incrementAndGet() > 1) assertContains(messages.last().toText(), "这轮回应还没等到，我再等一下。")
                UIMessage.assistant("这轮回应还没等到，我再等一下。")
            } else UIMessage.assistant("{\"tags\":[]}")
        }) { k, device, now ->
            val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "结果") }
            try {
                val receipt = k.nativeDialogue.submit(device, "silent", "核对合成清单")
                withTimeout(2_000) { started.await() }
                now.set(1_500); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { while (!k.orchestrationStore.dialogue.hasEvent("ack:${receipt.eventId}")) delay(10) }
                now.set(60_000); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { while (calls.get() < 2) delay(10) }
                now.set(120_000); k.nativeDialogue.evaluateFeedback()
                now.set(180_000); k.nativeDialogue.evaluateFeedback()
                assertEquals(2, calls.get(), "每个静默窗口只尝试一次")
                assertEquals(listOf("这轮回应还没等到，我再等一下。"), k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }.map { it.text }, "生成重复内容时也不得再冒泡")
            } finally { release.complete(Unit); k.router.awaitIdle() }
        }
    }

    @Test fun late_feedback_cannot_follow_a_final_answer() = runBlocking {
        val drafting = CompletableDeferred<Unit>(); val releaseDraft = CompletableDeferred<Unit>()
        fixture(CloudModelClient { messages, _ ->
            if (messages.first().toText().contains("<native-wait-feedback>")) {
                drafting.complete(Unit)
                withContext(NonCancellable) { releaseDraft.await() }
                UIMessage.assistant("迟到的等待说明")
            } else UIMessage.assistant("{\"tags\":[]}")
        }) { k, device, now ->
            val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "最终答复") }
            try {
                k.nativeDialogue.submit(device, "late", "核对合成清单")
                withTimeout(2_000) { started.await() }
                now.set(1_500); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { drafting.await() }
                release.complete(Unit)
                withTimeout(2_000) { k.router.awaitIdle() }
                releaseDraft.complete(Unit)
                k.nativeDialogue.closeAndJoin()
                assertEquals(listOf("最终答复"), k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }.map { it.text })
                assertEquals("consumed", k.nativeDialogue.receipt(device, "late")!!.state)
            } finally { release.complete(Unit); releaseDraft.complete(Unit) }
        }
    }

    @Test fun failed_waiting_generation_never_publishes_a_fallback_or_retries_each_tick() = runBlocking {
        val calls = AtomicInteger()
        fixture(CloudModelClient { messages, _ ->
            if (messages.first().toText().contains("<native-wait-feedback>")) {
                calls.incrementAndGet(); error("synthetic generation failure")
            }
            UIMessage.assistant("{\"tags\":[]}")
        }) { k, device, now ->
            val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "最终答复") }
            try {
                k.nativeDialogue.submit(device, "unavailable", "核对合成清单")
                withTimeout(2_000) { started.await() }
                now.set(1_500); k.nativeDialogue.evaluateFeedback()
                withTimeout(2_000) { while (calls.get() == 0) delay(10) }
                now.set(3_000); k.nativeDialogue.evaluateFeedback()
                assertEquals(1, calls.get())
                assertTrue(k.orchestrationStore.dialogue.page(0, 100).items.none { it.role == "assistant" })
                release.complete(Unit); k.router.awaitIdle()
                assertEquals(listOf("最终答复"), k.orchestrationStore.dialogue.page(0, 100).items.filter { it.role == "assistant" }.map { it.text })
            } finally { release.complete(Unit) }
        }
    }

    @Test fun slow_reply_uses_current_persona_and_turn_instead_of_system_template() = runBlocking {
        val dir = Files.createTempDirectory("native-persona-feedback").toFile()
        val now = AtomicLong(0)
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val expected = "这份清单我来理，你等我一下呀。"
        val k = CloudAgentKernel(dir, CloudModelClient { messages, tools ->
            if (!messages.first().toText().contains("<native-wait-feedback>")) return@CloudModelClient UIMessage.assistant("{\"tags\":[]}")
            assertTrue(tools.isEmpty(), "等待文案不得拥有执行工具")
            assertContains(messages.first().toText(), "阿澄")
            assertContains(messages.first().toText(), "温和、熟悉的口吻")
            assertContains(messages.last().toText(), "核对测试清单")
            UIMessage.assistant(expected)
        }, masterSecretOverride = "persona-feedback-fixture")
        k.nativeDialogue.clockMs = now::get
        k.soulStore.put(SoulPutRequestDto(displayName = "阿澄", soulMarkdown = "用温和、熟悉的口吻说话。", isDefault = false))
        k.router.brain = RouterBrain { started.complete(Unit); release.await(); RouterDecision(reply = "核对完成") }
        k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(), "ios", "fixture")
        val device = k.gatewayState.loadDevicesStrict().single()
        try {
            val receipt = k.nativeDialogue.submit(device, "slow", "核对测试清单")
            withTimeout(2_000) { started.await() }
            now.set(1_500); k.nativeDialogue.evaluateFeedback()
            withTimeout(2_000) {
                while (!k.orchestrationStore.dialogue.hasEvent("ack:${receipt.eventId}")) delay(10)
            }
            val feedback = k.orchestrationStore.dialogue.page(0, 100).items.single { it.id == "ack:${receipt.eventId}" }
            assertEquals(expected, feedback.text, "等待正文应来自当前人格与语境，不能是系统通用模板")
            assertEquals("received", k.nativeDialogue.receipt(device, "slow")!!.state)
        } finally {
            release.complete(Unit); k.router.awaitIdle(includeWorkers = true)
            k.nativeDialogue.closeAndJoin(); k.conversationTagger.closeAndJoin()
            k.agentRegistry.close(); k.orchestrationStore.close(); k.supertagStore.close()
            dir.deleteRecursively()
        }
    }
}
