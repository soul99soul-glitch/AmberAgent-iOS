package app.amber.ai.provider.openai

import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptTranscript
import app.amber.ai.provider.Model
import app.amber.ai.provider.ModelAbility
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.test.Test
import kotlin.test.assertEquals

class OpenAIResponsesForeignReasoningTest {
    @Test
    fun foreignClaudeEmptyBlocksDoNotInterruptTextOrToolReplay() {
        val history = listOf(
            UIMessage.user("hello"),
            UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
                UIMessagePart.Text("before"),
                claudeSigned(),
                UIMessagePart.Text("middle"),
                claudeRedacted(),
                UIMessagePart.Tool(
                    toolCallId = "call_weather",
                    toolName = "weather",
                    input = "{}",
                    output = listOf(UIMessagePart.Text("sunny")),
                ),
                UIMessagePart.Text("after"),
            )),
            UIMessage.user("continue"),
        )

        assertEquals(
            Json.parseToJsonElement("""[
                {"role":"user","content":"hello"},
                {"role":"assistant","content":[{"type":"output_text","text":"before"},{"type":"output_text","text":"middle"}]},
                {"type":"function_call","call_id":"call_weather","name":"weather","arguments":"{}"},
                {"type":"function_call_output","call_id":"call_weather","output":"sunny"},
                {"role":"assistant","content":"after"},
                {"role":"user","content":"continue"}
            ]"""),
            input(history),
        )
    }

    @Test
    fun opaqueOnlyClaudeAssistantAddsNoResponsesInputItem() {
        val history = listOf(
            UIMessage.user("hello"),
            UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
                claudeSigned(" \n"), claudeRedacted(),
            )),
            UIMessage.user("continue"),
        )

        assertEquals(
            Json.parseToJsonElement("""[{"role":"user","content":"hello"},{"role":"user","content":"continue"}]"""),
            input(history),
        )
    }

    @Test
    fun emptyOpenAIEncryptedReasoningStillReplaysNativeFields() {
        val native = UIMessagePart.Reasoning(reasoning = "", metadata = buildJsonObject {
            put("reasoning_id", "rs_native")
            put("encrypted_content", "encrypted-native")
            put("signature", "legacy-signature")
        })

        assertEquals(
            Json.parseToJsonElement("""[
                {"role":"user","content":"hello"},
                {"type":"reasoning","id":"rs_native","summary":[{"type":"summary_text","text":""}],"encrypted_content":"encrypted-native"},
                {"role":"user","content":"continue"}
            ]"""),
            input(listOf(
                UIMessage.user("hello"),
                UIMessage(role = MessageRole.ASSISTANT, parts = listOf(native)),
                UIMessage.user("continue"),
            )),
        )
    }

    @Test
    fun nonemptyOpenAIEncryptedReasoningKeepsNativeReplay() {
        val native = UIMessagePart.Reasoning(reasoning = "old thought", metadata = buildJsonObject {
            put("reasoning_id", "rs_native")
            put("encrypted_content", "encrypted-native")
            put("signature", "legacy-signature")
        })
        assertEquals(
            Json.parseToJsonElement("""[
                {"role":"user","content":"hello"},
                {"type":"reasoning","id":"rs_native","summary":[{"type":"summary_text","text":"old thought"}],"encrypted_content":"encrypted-native"},
                {"role":"assistant","content":"old answer"}
            ]"""),
            input(listOf(
                UIMessage.user("hello"),
                UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
                    native, UIMessagePart.Text("old answer"),
                )),
            )),
        )
    }

    @Test
    fun knownClaudeNonemptySignedReasoningDoesNotBecomeInvalidResponsesItem() {
        assertForeignReasoningOmitted(claudeSigned("old thought"))
    }

    @Test
    fun knownClaudeNonemptyRedactedReasoningDoesNotBecomeInvalidResponsesItem() {
        assertForeignReasoningOmitted(claudeRedacted().copy(reasoning = "foreign summary"))
    }

    @Test
    fun plainIdlessReasoningDoesNotBecomeInvalidResponsesItem() {
        assertForeignReasoningOmitted(UIMessagePart.Reasoning(reasoning = "old chat completion thought"))
    }

    @Test
    fun nativeReasoningIdReplaysWithoutEncryptedContent() {
        val native = UIMessagePart.Reasoning(reasoning = "native thought", metadata = buildJsonObject {
            put("reasoning_id", "rs_native")
        })
        assertEquals(
            Json.parseToJsonElement("""[
                {"role":"user","content":"hello"},
                {"type":"reasoning","id":"rs_native","summary":[{"type":"summary_text","text":"native thought"}]},
                {"role":"assistant","content":"native answer"}
            ]"""),
            input(listOf(
                UIMessage.user("hello"),
                UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
                    native, UIMessagePart.Text("native answer"),
                )),
            )),
        )
    }

    private fun assertForeignReasoningOmitted(reasoning: UIMessagePart.Reasoning) {
        assertEquals(
            Json.parseToJsonElement("""[
                {"role":"user","content":"hello"},
                {"role":"assistant","content":[{"type":"output_text","text":"before"},{"type":"output_text","text":"after"}]},
                {"role":"user","content":"continue"}
            ]"""),
            input(listOf(
                UIMessage.user("hello"),
                UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
                    UIMessagePart.Text("before"), reasoning, UIMessagePart.Text("after"),
                )),
                UIMessage.user("continue"),
            )),
        )
    }

    private fun input(history: List<UIMessage>): JsonArray {
        val canonicalBefore = Json.encodeToString(history)
        val prepared = PromptTranscript.prepare(
            canonicalMessages = history,
            preparedMessages = listOf(PromptTranscript.sectionMessage("rules", "Be helpful")) + history,
            tools = emptyList(),
        )
        val body = OpenAIKmpProvider().buildResponsesRequestBody(
            providerSetting = ProviderSetting.OpenAI(
                apiKey = "sk-test", baseUrl = "https://api.openai.com/v1", useResponseApi = true,
            ),
            messages = prepared.messages,
            params = TextGenerationParams(model = Model(
                modelId = "gpt-5.4", abilities = listOf(ModelAbility.REASONING, ModelAbility.TOOL),
            )),
            stream = false,
        )
        assertEquals(canonicalBefore, Json.encodeToString(history))
        assertEquals(history, prepared.messages.filter { it.role != MessageRole.SYSTEM })
        return body.getValue("input").jsonArray
    }

    private fun claudeSigned(text: String = "") = UIMessagePart.Reasoning(
        reasoning = text,
        metadata = buildJsonObject { put("signature", "claude-signature") },
    )

    private fun claudeRedacted() = UIMessagePart.Reasoning(
        reasoning = "",
        metadata = buildJsonObject {
            putJsonObject("claude_redacted_thinking") {
                put("type", "redacted_thinking")
                put("data", "claude-encrypted-data")
            }
        },
    )
}
