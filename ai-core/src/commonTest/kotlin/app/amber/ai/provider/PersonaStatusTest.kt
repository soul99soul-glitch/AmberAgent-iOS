package app.amber.ai.provider

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PersonaStatusTest {
    private class Request : PersonaStatusRequest {
        val started = CompletableDeferred<Pair<String, PersonaStatusReply>>()
        val stopped = CompletableDeferred<Unit>()
        val published = CompletableDeferred<String?>()

        override fun start(prompt: String, reply: PersonaStatusReply) {
            started.complete(prompt to reply)
        }
        override fun cancel() { stopped.complete(Unit) }
        override fun publish(phrase: String?) { published.complete(phrase) }
    }

    @Test
    fun statusUsesATextOnlyRequestWithoutChangingTheSessionModel() {
        val model = Model(modelId = "fast", tools = setOf(BuiltInTools.Search))
        val headers = listOf(CustomHeader("X-Session", "fixture"))
        val request = model.personaStatusParams(headers)
        assertTrue(request.model.tools.isEmpty())
        assertEquals(setOf(BuiltInTools.Search), model.tools)
        assertEquals(model.id, request.model.id)
        assertEquals(24, request.maxTokens)
        assertFalse(request.reasoningLevel.isEnabled)
        assertEquals(headers, request.customHeaders)
    }

    @Test
    fun acceptsShortSinglePhrasesOnly() {
        assertEquals("在哄着呢", cleanPersonaStatus("\n「在哄着呢。」\n"))
        assertEquals("Let me check", cleanPersonaStatus("Let me check…"))
        listOf(null, "", "好", "我要仔细想想应该怎么来哄你", "{\"phrase\":\"哄你\"}",
            "<think>思考</think>", "思考\n哄你", "This phrase is far too long", "null", "true"
        ).forEach { assertNull(cleanPersonaStatus(it), it) }
    }

    @Test
    fun additionReplacesAnInflightRequestAndIncludesBoundedPersonaAndHistory() = runBlocking {
        val owner = PersonaStatusController(this, 1, 2500)
        val old = Request()
        owner.refresh("赵大哥", "", emptyList(), "你好", false, old)
        val lateReply = old.started.await().second
        val skipped = Request()
        owner.refresh("赵大哥", "", emptyList(), "先等等", true, skipped)
        val next = Request()
        owner.refresh("赵大哥", "甲".repeat(301), listOf("过期上下文", "一", "二", "三", "四"), "哄我", true, next)
        old.stopped.await()
        lateReply.submit("旧状态")
        val (prompt, reply) = next.started.await()
        assertTrue(prompt.contains("助手：赵大哥"))
        assertTrue(prompt.contains("甲".repeat(300)))
        assertFalse(prompt.contains("甲".repeat(301)))
        assertFalse(prompt.contains("过期上下文"))
        assertTrue(prompt.endsWith("用户刚刚追加：哄我"))
        reply.submit("「在哄着呢」")
        assertEquals("在哄着呢", next.published.await())
        assertFalse(old.published.isCompleted)
        assertFalse(skipped.started.isCompleted)
    }

    @Test
    fun failureAndTimeoutYieldDefaultAndDropLateReply() = runBlocking {
        val owner = PersonaStatusController(this, 1, 25)
        val timedOut = Request()
        owner.refresh("", "", emptyList(), "消息", false, timedOut)
        val reply = timedOut.started.await().second
        assertNull(timedOut.published.await())
        assertTrue(timedOut.stopped.isCompleted)
        reply.submit("来晚了")
        val failed = Request()
        owner.refresh("", "", emptyList(), "消息", false, failed)
        failed.started.await().second.submit(null)
        assertNull(failed.published.await())
    }

    @Test
    fun clearOnBodyToolOrTerminationDiscardsRunningAndDebouncedRequests() = runBlocking {
        val owner = PersonaStatusController(this, 150, 2500)
        val active = Request()
        owner.refresh("", "", emptyList(), "消息", false, active)
        val reply = active.started.await().second
        owner.clear()
        active.stopped.await()
        reply.submit("已过期")
        assertFalse(active.published.isCompleted)

        val queued = Request()
        owner.refresh("", "", emptyList(), "追加", true, queued)
        owner.clear()
        assertFalse(queued.started.isCompleted)
    }
}
