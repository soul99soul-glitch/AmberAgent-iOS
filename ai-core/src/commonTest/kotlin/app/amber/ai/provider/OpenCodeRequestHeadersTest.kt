package app.amber.ai.provider

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class OpenCodeRequestHeadersTest {
    private val userId = Uuid.parse("00000000-0000-0000-0000-000000000101")
    private val assistantId = Uuid.parse("00000000-0000-0000-0000-000000000102")

    @Test
    fun endpointMatchesAuthorityHostOnly() {
        assertTrue(OpenCodeRequestHeaders.isOpenCodeEndpoint("https://opencode.ai/zen/go/v1"))
        assertTrue(OpenCodeRequestHeaders.isOpenCodeEndpoint("HTTPS://OPENCODE.AI:443/v1"))
        assertFalse(OpenCodeRequestHeaders.isOpenCodeEndpoint("https://opencode.ai.example/v1"))
        assertFalse(OpenCodeRequestHeaders.isOpenCodeEndpoint("https://example.com/opencode.ai/v1"))
        assertFalse(OpenCodeRequestHeaders.isOpenCodeEndpoint("https://user:pass@opencode.ai.example/v1"))
    }

    @Test
    fun generationUsesFirstUserIdAndDefaultUserAgent() {
        val headers = OpenCodeRequestHeaders.forGeneration(
            baseUrl = "https://opencode.ai/zen/go/v1",
            messages = listOf(
                UIMessage(
                    id = assistantId,
                    role = MessageRole.ASSISTANT,
                    parts = listOf(UIMessagePart.Text("previous")),
                ),
                UIMessage(
                    id = userId,
                    role = MessageRole.USER,
                    parts = listOf(UIMessagePart.Text("hello")),
                ),
            ),
        )

        assertEquals(userId.toString(), headers.single { it.name == OpenCodeRequestHeaders.SESSION_HEADER }.value)
        assertEquals(OpenCodeRequestHeaders.DEFAULT_USER_AGENT, headers.single { it.name == "User-Agent" }.value)
    }

    @Test
    fun explicitSessionAndUserAgentArePreservedCaseInsensitively() {
        val headers = OpenCodeRequestHeaders.forGeneration(
            baseUrl = "https://opencode.ai/zen/go/v1",
            messages = emptyList(),
            customHeaders = listOf(
                CustomHeader("X-OpenCode-Session", "provided-session"),
                CustomHeader("user-agent", "provided-agent"),
                CustomHeader("X-Trace", "trace-value"),
            ),
        )

        assertEquals("provided-session", headers.single { it.name.equals("x-opencode-session", true) }.value)
        assertEquals("provided-agent", headers.single { it.name.equals("user-agent", true) }.value)
        assertEquals("trace-value", headers.single { it.name == "X-Trace" }.value)
    }

    @Test
    fun nonOpenCodeEndpointDoesNotAddGeneratedHeaders() {
        val headers = OpenCodeRequestHeaders.forGeneration(
            baseUrl = "https://api.openai.com/v1",
            messages = listOf(UIMessage(id = userId, role = MessageRole.USER, parts = emptyList())),
            customHeaders = listOf(CustomHeader("X-Trace", "trace-value")),
        )

        assertEquals(listOf(CustomHeader("X-Trace", "trace-value")), headers)
        assertFalse(headers.any { it.name.equals("x-opencode-session", true) })
        assertFalse(headers.any { it.name.equals("user-agent", true) })
    }

    @Test
    fun noUserFallsBackToFirstMessageId() {
        val headers = OpenCodeRequestHeaders.forGeneration(
            baseUrl = "https://opencode.ai/zen/go/v1",
            messages = listOf(UIMessage(id = assistantId, role = MessageRole.ASSISTANT, parts = emptyList())),
        )

        assertEquals(assistantId.toString(), headers.single { it.name == OpenCodeRequestHeaders.SESSION_HEADER }.value)
    }
}
