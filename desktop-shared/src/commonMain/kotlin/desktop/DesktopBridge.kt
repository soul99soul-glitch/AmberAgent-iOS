@file:OptIn(kotlin.uuid.ExperimentalUuidApi::class)

package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.core.Tool
import app.amber.ai.provider.Model
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.provider.TextGenerationParams
import app.amber.ai.ui.ToolApprovalState
import app.amber.ai.provider.openai.OpenAIKmpProvider
import app.amber.ai.provider.claude.ClaudeKmpProvider
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.core.agent.utils.JsonInstant
import app.amber.core.model.Conversation
import app.amber.core.model.DEFAULT_ASSISTANT_ID
import app.amber.core.model.MessageNode
import app.amber.core.model.toMessageNode
import app.amber.core.storage.conversation.ConversationFile
import app.amber.core.storage.conversation.JsonConversationStorage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.time.Clock
import kotlin.time.Instant
import kotlin.uuid.Uuid

private val desktopJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

@Serializable
internal data class DesktopMessageImage(val url: String, val name: String? = null)

/** Display-only view of a tool call; the canonical part stays in `canonicalJSON`. */
@Serializable
internal data class DesktopToolCall(
    val id: String,
    val name: String,
    val input: String = "",
    val output: String = "",
    val status: String = "complete",
) {
    companion object {
        private const val INPUT_LIMIT = 4_000
        private const val OUTPUT_LIMIT = 8_000

        fun from(part: UIMessagePart.Tool): DesktopToolCall {
            val output = part.output.joinToString("\n") { result ->
                when (result) {
                    is UIMessagePart.Text -> result.text
                    is UIMessagePart.Image -> "[图片]"
                    else -> "[附件]"
                }
            }
            val status = when {
                part.approvalState is ToolApprovalState.Denied -> "denied"
                part.isPending -> "pending"
                part.isExecuted -> "complete"
                else -> "running"
            }
            return DesktopToolCall(part.toolCallId, part.toolName, part.input.clipped(INPUT_LIMIT), output.clipped(OUTPUT_LIMIT), status)
        }

        private fun String.clipped(limit: Int): String = if (length <= limit) this else take(limit) + "\n…"
    }
}

@Serializable
internal data class DesktopMessage(
    val id: String,
    val role: String,
    val text: String = "",
    val reasoning: String = "",
    val state: String = "complete",
    val canonicalJSON: String? = null,
    val unsupportedPartCount: Int = 0,
    val nodeID: String? = null,
    val variantIDs: List<String> = emptyList(),
    val editableTextPartIndex: Int? = null,
    val editableText: String? = null,
    val estimatedTokens: Int? = null,
    val images: List<DesktopMessageImage> = emptyList(),
    val tools: List<DesktopToolCall> = emptyList(),
) {
    fun toMessage(existing: UIMessage? = null): UIMessage {
        require(state in setOf("complete", "streaming", "cancelled", "failed")) { "Unknown message state: $state" }
        val messageRole = when (role) {
            "user" -> MessageRole.USER
            "assistant" -> MessageRole.ASSISTANT
            "system" -> MessageRole.SYSTEM
            "tool" -> MessageRole.TOOL
            else -> error("Unknown message role: $role")
        }
        val source = canonicalJSON?.let { JsonInstant.decodeFromString<UIMessage>(it) } ?: existing
        val message = if (source == null) {
            UIMessage(
                id = Uuid.parse(id), role = messageRole,
                parts = buildList {
                    if (reasoning.isNotEmpty()) add(UIMessagePart.Reasoning(reasoning))
                    add(UIMessagePart.Text(text))
                },
            )
        } else {
            require(source.role == messageRole) { "Message role disagrees with canonical payload" }
            val content = if (canonicalJSON == null) source.withLegacyContent(text, reasoning) else source
            content.copy(id = Uuid.parse(id))
        }
        return message.withDesktopState(state)
    }

    companion object {
        fun from(message: UIMessage, node: MessageNode? = null): DesktopMessage = DesktopMessage(
            id = message.id.toString(),
            role = message.role.name.lowercase(),
            text = message.parts.filterIsInstance<UIMessagePart.Text>().joinToString("") { it.text },
            reasoning = message.parts.filterIsInstance<UIMessagePart.Reasoning>().joinToString("") { it.reasoning },
            state = message.desktopState(),
            canonicalJSON = JsonInstant.encodeToString(message),
            unsupportedPartCount = message.parts.count { it !is UIMessagePart.Text && it !is UIMessagePart.Reasoning && it !is UIMessagePart.Image && it !is UIMessagePart.Tool },
            nodeID = node?.id?.toString(),
            variantIDs = node?.messages?.map { it.id.toString() }.orEmpty(),
            editableTextPartIndex = message.parts.indexOfFirst { it is UIMessagePart.Text }.takeIf { it >= 0 },
            editableText = message.parts.filterIsInstance<UIMessagePart.Text>().firstOrNull()?.text,
            estimatedTokens = estimateDesktopMessageTokens(message),
            images = message.parts.filterIsInstance<UIMessagePart.Image>().map {
                DesktopMessageImage(it.url, it.metadata?.get("fileName")?.jsonPrimitive?.contentOrNull)
            },
            tools = message.parts.filterIsInstance<UIMessagePart.Tool>().map(DesktopToolCall::from),
        )
    }
}

private fun UIMessage.desktopState(): String = parts.filterIsInstance<UIMessagePart.Text>()
    .firstNotNullOfOrNull { it.metadata?.get("desktopState")?.jsonPrimitive?.contentOrNull } ?: "complete"

private fun UIMessage.withDesktopState(state: String): UIMessage {
    if (desktopState() == state) return this
    var assigned = false
    val updated = parts.map { part ->
        if (part is UIMessagePart.Text && (!assigned || part.metadata?.containsKey("desktopState") == true)) {
            assigned = true
            part.copy(metadata = JsonObject(part.metadata.orEmpty() + ("desktopState" to JsonPrimitive(state))))
        } else part
    }
    return copy(parts = if (assigned) updated else updated + UIMessagePart.Text(
        "", buildJsonObject { put("desktopState", state) }
    ))
}

private fun UIMessage.withLegacyContent(text: String, reasoning: String): UIMessage {
    val textParts = parts.filterIsInstance<UIMessagePart.Text>()
    val reasoningParts = parts.filterIsInstance<UIMessagePart.Reasoning>()
    if (textParts.joinToString("") { it.text } == text && reasoningParts.joinToString("") { it.reasoning } == reasoning) return this
    require(textParts.size <= 1 && reasoningParts.size <= 1) { "Full message JSON is required to edit mixed text content" }
    val updated = parts.map { part -> when (part) {
        is UIMessagePart.Text -> part.copy(text = text)
        is UIMessagePart.Reasoning -> part.copy(reasoning = reasoning)
        else -> part
    } }.toMutableList()
    if (textParts.isEmpty() && text.isNotEmpty()) updated += UIMessagePart.Text(text)
    if (reasoningParts.isEmpty() && reasoning.isNotEmpty()) updated += UIMessagePart.Reasoning(reasoning)
    return copy(parts = updated)
}

@Serializable
internal data class DesktopConversation(
    val id: String,
    val title: String,
    val updatedAt: Double,
    val isPinned: Boolean = false,
    val messages: List<DesktopMessage> = emptyList(),
    val canonicalJSON: String? = null,
) {
    fun toConversation(existing: Conversation? = null): Conversation {
        require(updatedAt.isFinite()) { "Invalid conversation timestamp" }
        val incomingID = Uuid.parse(id)
        val base = existing ?: canonicalJSON?.let { JsonInstant.decodeFromString<Conversation>(it) }
            ?: Conversation(id = incomingID, assistantId = DEFAULT_ASSISTANT_ID, title = title,
                isPinned = isPinned, messageNodes = emptyList())
        base.validateDesktopSelection()
        val originals = base.messageNodes.flatMap { it.messages }.associateBy { it.id }
        val incoming = messages.map { it.toMessage(originals[Uuid.parse(it.id)]) }
        // The DTO contains the complete selected path. A shorter path explicitly removes its trailing nodes.
        val selectedPath = if (incoming.size < base.messageNodes.size) base.copy(messageNodes = base.messageNodes.take(incoming.size)) else base
        val updated = selectedPath.updateCurrentMessages(incoming)
        val timestamp = if (updatedAt == base.updateAt.toEpochMilliseconds().toDouble()) base.updateAt
            else Instant.fromEpochMilliseconds(updatedAt.toLong())
        return updated.copy(id = incomingID, updateAt = timestamp)
    }

    companion object {
        fun from(conversation: Conversation): DesktopConversation {
            conversation.validateDesktopSelection()
            return DesktopConversation(
                id = conversation.id.toString(), title = conversation.title,
                updatedAt = conversation.updateAt.toEpochMilliseconds().toDouble(), isPinned = conversation.isPinned,
                messages = conversation.messageNodes.map { DesktopMessage.from(it.currentMessage, it) },
                canonicalJSON = JsonInstant.encodeToString(conversation),
            )
        }
    }
}

private fun Conversation.validateDesktopSelection() {
    require(messageNodes.all { it.selectIndex in it.messages.indices }) { "Conversation has an invalid selected message variant" }
}

/** Typed Swift entry points over the same providers and message types used by iOS. */
object DesktopProviderBridge {
    @Throws(Throwable::class)
    fun declarations(json: String): List<Tool> = desktopDeclarations(json)

    @Throws(Throwable::class)
    fun projectMessages(messages: List<UIMessage>): String = snapshot(messages)

    @Throws(Throwable::class)
    fun toolInvocation(callId: String, name: String, arguments: String): UIMessage {
        require(callId.isNotBlank() && name.isNotBlank()) { "A tool invocation requires stable call and tool names" }
        require(desktopJson.parseToJsonElement(arguments) is JsonObject) { "Tool arguments must be a JSON object" }
        return UIMessage(role = MessageRole.ASSISTANT, parts = listOf(UIMessagePart.Tool(
            toolCallId = callId, toolName = name, input = arguments, output = emptyList(),
        )))
    }

    @Throws(Throwable::class)
    fun agentRequestHistory(messages: List<UIMessage>): List<UIMessage> = messages.map { message ->
        val parts = message.parts.map { part ->
            if (part is UIMessagePart.Tool && part.output.isEmpty()) part.copy(output = listOf(UIMessagePart.Text(
                buildJsonObject {
                    put("ok", false)
                    put("status", "not_resumed")
                    put("tool_call_id", part.toolCallId)
                    put("reason", "前次调用结果未确认，禁止自动重放，请先核对")
                }.toString()
            ))) else part
        }
        if (parts == message.parts) message else message.copy(parts = parts)
    }

    @Throws(Throwable::class)
    fun configuration(kind: String, id: String, name: String, baseUrl: String, apiKey: String): ProviderSetting {
        val providerId = Uuid.parse(id)
        val endpoint = baseUrl.trim().trimEnd('/')
        return when (kind) {
            "openai", "responses" -> ProviderSetting.OpenAI(
                id = providerId, name = name, baseUrl = endpoint, apiKey = apiKey, useResponseApi = kind == "responses",
            )
            "claude" -> ProviderSetting.Claude(id = providerId, name = name, baseUrl = endpoint, apiKey = apiKey)
            "gemini" -> ProviderSetting.Google(id = providerId, name = name, baseUrl = endpoint, apiKey = apiKey)
            else -> error("Unsupported provider protocol: $kind")
        }
    }

    fun params(modelID: String): TextGenerationParams = TextGenerationParams(model = Model(modelId = modelID))

    @Throws(Throwable::class)
    fun paramsFromJSON(json: String): TextGenerationParams = desktopModelParams(json)

    @Throws(Throwable::class)
    fun searchSettings(json: String): app.amber.core.settings.Settings =
        desktopJson.decodeFromString<app.amber.core.settings.Settings>(json)

    @Throws(Throwable::class)
    fun configurationWithAuth(kind: String, id: String, name: String, baseUrl: String, apiKey: String,
        authMode: String): ProviderSetting = desktopAuthenticatedConfiguration(kind, id, name, baseUrl, apiKey, authMode)

    fun withCodexHeaders(params: TextGenerationParams, accountID: String?, originator: String): TextGenerationParams = desktopCodexHeaders(params, accountID, originator)

    fun catalogJSON(models: List<Model>): String = desktopCatalogJSON(models)

    @Throws(Throwable::class)
    suspend fun listModelsOrThrow(kind: String, id: String, name: String, baseUrl: String, apiKey: String,
        authMode: String = "apiKey"): String = withContext(Dispatchers.Default) {
        val provider = desktopAuthenticatedConfiguration(kind, id, name, baseUrl, apiKey, authMode)
        desktopCatalogJSON(when (provider) {
            is ProviderSetting.OpenAI -> catalogOpenAI.listModelsOrThrow(provider)
            is ProviderSetting.Claude -> catalogClaude.listModelsOrThrow(provider)
            else -> error("Gemini model listing uses the native Gemini client")
        })
    }

    private val catalogOpenAI by lazy { OpenAIKmpProvider() }
    private val catalogClaude by lazy { ClaudeKmpProvider() }

    @Throws(Throwable::class)
    fun messages(json: String): List<UIMessage> = desktopJson.decodeFromString<List<DesktopMessage>>(json).map { it.toMessage() }

    @Throws(Throwable::class)
    fun userMessage(id: String, text: String, attachmentsJSON: String): String =
        desktopJson.encodeToString(desktopUserMessage(id, text, attachmentsJSON))

    @Throws(Throwable::class)
    fun snapshot(messages: List<UIMessage>, assistantId: String? = null): String {
        val stableID = assistantId?.let(Uuid::parse)
        val lastAssistant = if (stableID == null) -1 else messages.indexOfLast { it.role == MessageRole.ASSISTANT }
        return desktopJson.encodeToString(messages.mapIndexed { index, message ->
            DesktopMessage.from(if (index == lastAssistant) message.copy(id = stableID!!) else message)
        })
    }
}

/** macOS stores canonical KMP documents; the envelope is only a Swift display projection. */
class DesktopConversationRepository(directory: String) {
    private val storage by lazy { JsonConversationStorage(ConversationFile(directory)) }

    @Throws(Throwable::class)
    suspend fun listSummaries(): String = withContext(Dispatchers.Default) {
        desktopJson.encodeToString(storage.listSummaries().map { it.desktopSummary() })
    }

    @Throws(Throwable::class)
    suspend fun search(query: String): String = withContext(Dispatchers.Default) {
        desktopJson.encodeToString(desktopSearch(storage, query))
    }

    @Throws(Throwable::class)
    suspend fun remapMemoryCitations(json: String, mappingJSON: String): String = withContext(Dispatchers.Default) {
        val mapping = desktopMemoryMapping(mappingJSON)
        val current = desktopJson.decodeFromString<DesktopConversation>(json).toConversation()
        val updated = current.copy(messageNodes = current.messageNodes.map { node ->
            node.copy(messages = node.messages.map { message ->
                message.copy(parts = message.parts.map { it.remapDesktopMemoryCitations(mapping) })
            })
        })
        desktopJson.encodeToString(DesktopConversation.from(updated))
    }

    @Throws(Throwable::class)
    suspend fun loadAll(): String = withContext(Dispatchers.Default) {
        desktopJson.encodeToString(storage.listSummaries().mapNotNull { summary ->
            storage.loadConversation(summary.id)?.let(DesktopConversation::from)
        })
    }

    @Throws(Throwable::class)
    suspend fun load(id: String): String? = withContext(Dispatchers.Default) {
        storage.loadConversation(Uuid.parse(id))?.let { desktopJson.encodeToString(DesktopConversation.from(it)) }
    }

    @Throws(Throwable::class)
    suspend fun save(json: String): String = withContext(Dispatchers.Default) {
        val envelope = desktopJson.decodeFromString<DesktopConversation>(json)
        val incoming = envelope.toConversation(storage.loadConversation(Uuid.parse(envelope.id)))
        desktopJson.encodeToString(DesktopConversation.from(storage.saveConversation(incoming)))
    }

    @Throws(Throwable::class)
    suspend fun regenerate(json: String, messageId: String, responseId: String): String = changeConversation(json) { current ->
        val index = current.selectedNodeIndex(messageId)
        val node = current.messageNodes[index]
        require(node.currentMessage.role == MessageRole.ASSISTANT) { "Only assistant replies can be regenerated" }
        require(current.messageNodes.take(index).any { it.currentMessage.role == MessageRole.USER }) {
            "Regeneration requires a preceding user message"
        }
        val response = current.newAssistant(responseId)
        current.copy(messageNodes = current.messageNodes.take(index) + node.copy(
            messages = node.messages + response, selectIndex = node.messages.size,
        ), updateAt = Clock.System.now())
    }

    @Throws(Throwable::class)
    suspend fun editMessage(json: String, messageId: String, textPartIndex: Int, text: String, responseId: String): String = changeConversation(json) { current ->
        val index = current.selectedNodeIndex(messageId)
        val node = current.messageNodes[index]
        val selected = node.currentMessage
        require(selected.role == MessageRole.USER) { "Only user messages can be edited and resent" }
        val originalPart = selected.parts.getOrNull(textPartIndex)
        require(originalPart is UIMessagePart.Text) { "Selected message part is not editable text" }
        val editedParts = selected.parts.toMutableList().also { it[textPartIndex] = originalPart.copy(text = text) }
        val edited = selected.copy(id = Uuid.random(), parts = editedParts)
        val editedNode = node.copy(messages = node.messages + edited, selectIndex = node.messages.size)
        val response = current.newAssistant(responseId)
        current.copy(messageNodes = current.messageNodes.take(index) + editedNode + response.toMessageNode(),
            updateAt = Clock.System.now())
    }

    @Throws(Throwable::class)
    suspend fun deleteMessage(json: String, messageId: String): String = changeConversation(json) { current ->
        val index = current.selectedNodeIndex(messageId)
        current.copy(messageNodes = current.messageNodes.filterIndexed { position, _ -> position != index },
            updateAt = Clock.System.now())
    }

    @Throws(Throwable::class)
    suspend fun selectVariant(json: String, messageId: String, variantId: String): String = changeConversation(json) { current ->
        val index = current.selectedNodeIndex(messageId)
        val node = current.messageNodes[index]
        val target = Uuid.parse(variantId)
        val selected = node.messages.indexOfFirst { it.id == target }
        require(selected >= 0) { "Message variant does not belong to this node" }
        if (selected == node.selectIndex) current else current.copy(
            messageNodes = current.messageNodes.toMutableList().also { it[index] = node.copy(selectIndex = selected) },
            updateAt = Clock.System.now(),
        )
    }

    private suspend fun changeConversation(json: String, change: (Conversation) -> Conversation): String = withContext(Dispatchers.Default) {
        val envelope = desktopJson.decodeFromString<DesktopConversation>(json)
        val current = envelope.toConversation(storage.loadConversation(Uuid.parse(envelope.id)))
        val changed = change(current)
        val actual = if (changed == current) current else storage.saveConversation(changed)
        desktopJson.encodeToString(DesktopConversation.from(actual))
    }

    @Throws(Throwable::class)
    suspend fun exportDocument(json: String): String = withContext(Dispatchers.Default) {
        val envelope = desktopJson.decodeFromString<DesktopConversation>(json)
        // A failed disk save must still allow a backup of the complete in-memory snapshot.
        val existing = runCatching { storage.loadConversation(Uuid.parse(envelope.id)) }.getOrElse {
            if (it is CancellationException) throw it
            null
        }
        val exported = envelope.toConversation(existing).copy(title = envelope.title, isPinned = envelope.isPinned)
        JsonInstant.encodeToString(exported)
    }

    @Throws(Throwable::class)
    suspend fun normalizeImport(document: String): String = withContext(Dispatchers.Default) {
        val root = desktopJson.parseToJsonElement(document).jsonObject
        val format = root["format"]?.jsonPrimitive?.contentOrNull
        val conversation = if (format != null) {
            require(format == "amber.mac.conversation.v1") { "Unsupported conversation export format" }
            val envelope = desktopJson.decodeFromJsonElement<DesktopConversation>(root.getValue("conversation"))
            envelope.toConversation().copy(title = envelope.title, isPinned = envelope.isPinned)
        } else {
            require(root.containsKey("messageNodes")) { "Not a canonical conversation document" }
            JsonInstant.decodeFromJsonElement<Conversation>(root)
        }
        desktopJson.encodeToString(DesktopConversation.from(conversation))
    }

    @Throws(Throwable::class)
    suspend fun delete(id: String) = withContext(Dispatchers.Default) { storage.deleteConversation(Uuid.parse(id)) }

    @Throws(Throwable::class)
    suspend fun updateMetadata(id: String, title: String?, pinned: Boolean?) = withContext(Dispatchers.Default) {
        storage.updateMetadata(Uuid.parse(id), title, pinned)
    }
}


private fun Conversation.selectedNodeIndex(messageId: String): Int {
    val target = Uuid.parse(messageId)
    val index = messageNodes.indexOfFirst { it.currentMessage.id == target }
    require(index >= 0) { "Message is no longer selected in this conversation" }
    return index
}

private fun Conversation.newAssistant(responseId: String): UIMessage {
    val target = Uuid.parse(responseId)
    require(messageNodes.none { node -> node.messages.any { it.id == target } }) { "A new reply requires a new message ID" }
    return UIMessage(id = target, role = MessageRole.ASSISTANT, parts = listOf(UIMessagePart.Text("")))
        .withDesktopState("streaming")
}
