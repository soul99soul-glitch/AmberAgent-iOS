package app.amber.ai.core

import app.amber.ai.provider.Model
import app.amber.ai.provider.OpenAIAuthMode
import app.amber.ai.provider.ProviderSetting
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.ai.util.json
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonPrimitive

const val PROMPT_SECTION_METADATA = "amber_prompt_section"
private const val PROMPT_EVENT_METADATA = "amber_prompt_transition_v1"

/** Only declarations cross the persistence boundary; executable closures never do. */
@Serializable
data class PromptToolDeclaration(val name: String, val description: String, val parameters: InputSchema? = null)

@Serializable
data class PromptTranscriptEvent(
    val initial: Boolean = false,
    val sections: Map<String, String?> = emptyMap(),
    val toolsAdded: List<PromptToolDeclaration> = emptyList(),
    val toolsRemoved: List<String> = emptyList(),
    val sectionMetadata: Map<String, JsonObject> = emptyMap(),
)

data class PromptTranscriptRequest(val messages: List<UIMessage>, val pendingEvent: PromptTranscriptEvent?)

data class PromptTranscriptView(
    val messages: List<UIMessage>,
    val initialTools: List<PromptToolDeclaration>,
    val currentTools: List<PromptToolDeclaration>,
    val hasNonAdditiveToolChanges: Boolean,
    val hasToolRedefinitions: Boolean,
    val hasTranscript: Boolean,
)

/** Endpoint-specific, deliberately closed allowlist. API compatibility alone proves nothing. */
data class PromptTranscriptCapabilities(
    val systemUpdates: Boolean = false,
    val toolAdditions: Boolean = false,
    val toolRemovals: Boolean = false,
    val responsesToolSearch: Boolean = false,
) {
    companion object {
        fun resolve(setting: ProviderSetting, model: Model): PromptTranscriptCapabilities {
            val id = model.modelId.lowercase()
            fun host(url: String) = url.substringAfter("://", "").substringBefore('/').lowercase()
            return when (setting) {
                is ProviderSetting.OpenAI -> {
                    val host = host(setting.baseUrl)
                    val codex = setting.authMode == OpenAIAuthMode.CODEX_OAUTH && host == "chatgpt.com"
                    val responsesModel = id in setOf(
                        "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.5",
                        "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra",
                    )
                    when {
                        (setting.useResponseApi || codex) && responsesModel && (host == "api.openai.com" || codex) ->
                            PromptTranscriptCapabilities(true, true, responsesToolSearch = codex && id in setOf(
                                "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.5",
                            ))
                        !setting.useResponseApi && host in setOf("api.moonshot.ai", "api.moonshot.cn") &&
                            id in setOf("kimi-k3", "kimi-k2.6", "kimi-k2.7-code", "kimi-k2.7-code-highspeed") ->
                            PromptTranscriptCapabilities(true, id == "kimi-k3")
                        !setting.useResponseApi && host == "api.deepseek.com" && id == "deepseek-v4-pro" ->
                            PromptTranscriptCapabilities(systemUpdates = true)
                        else -> PromptTranscriptCapabilities()
                    }
                }
                is ProviderSetting.Claude -> if (host(setting.baseUrl) == "api.anthropic.com" &&
                    id in setOf("claude-opus-4-8", "claude-opus-5", "claude-fable-5", "claude-fable-5-1")) {
                    PromptTranscriptCapabilities(true, true, true)
                } else PromptTranscriptCapabilities()
                else -> PromptTranscriptCapabilities()
            }
        }
    }
}

/**
 * Request-only system transitions are anchored to the assistant response that consumed them.
 * Metadata already travels with message branches, tool outputs, background handoffs and exports.
 * The UI text and the canonical message order stay unchanged.
 */
object PromptTranscript {
    // JsonObject is bridged as NSDictionary. Never pass part.metadata back through a
    // Swift initializer: Kotlin/Native then sees an invalid JsonObject implementation.
    fun copyTool(tool: UIMessagePart.Tool, input: String, output: List<UIMessagePart>): UIMessagePart.Tool =
        tool.copy(input = input, output = output)

    fun copyText(part: UIMessagePart.Text, text: String): UIMessagePart.Text = part.copy(text = text)

    /** Restore exposure by name only; the caller's live registry filters removed/disabled tools. */
    fun currentToolNames(messages: List<UIMessage>): List<String> =
        replay(messages.filter { it.role == MessageRole.ASSISTANT }.mapNotNull(::event))?.tools?.keys?.toList().orEmpty()

    fun declarations(tools: List<Tool>): List<PromptToolDeclaration> = tools.map {
        PromptToolDeclaration(it.name, it.description, it.parameters())
    }

    fun sectionMessage(name: String, text: String): UIMessage = UIMessage(
        role = MessageRole.SYSTEM,
        parts = listOf(UIMessagePart.Text(text, JsonObject(mapOf(PROMPT_SECTION_METADATA to JsonPrimitive(name))))),
    )

    fun event(message: UIMessage): PromptTranscriptEvent? {
        if (message.role != MessageRole.SYSTEM && message.role != MessageRole.ASSISTANT) return null
        return runCatching {
            val value = message.parts.firstNotNullOfOrNull { it.metadata?.get(PROMPT_EVENT_METADATA) }
                ?: return@runCatching null
            if (value is JsonPrimitive) json.decodeFromString<PromptTranscriptEvent>(value.content)
            else json.decodeFromJsonElement<PromptTranscriptEvent>(value)
        }.getOrNull()
    }

    fun recordResponse(message: UIMessage, request: PromptTranscriptRequest): UIMessage {
        val event = request.pendingEvent ?: return message
        if (message.role != MessageRole.ASSISTANT || message.parts.isEmpty()) return message
        return message.copy(parts = listOf(withEvent(message.parts.first(), event)) + message.parts.drop(1))
    }

    fun prepare(
        canonicalMessages: List<UIMessage>,
        preparedMessages: List<UIMessage>,
        tools: List<Tool>,
    ): PromptTranscriptRequest {
        val desired = systemState(preparedMessages).also { state ->
            state.tools.clear()
            declarations(tools).forEach { state.tools[it.name] = it }
        }
        val conversation = preparedMessages.filter { it.role != MessageRole.SYSTEM }
        val canonical = canonicalMessages.filter { it.role != MessageRole.SYSTEM }
        val retainedIds = conversation.mapTo(mutableSetOf()) { it.id }
        val firstRetained = canonical.indexOfFirst { it.id in retainedIds }.let { if (it < 0) canonical.size else it }
        val earlier = canonical.take(firstRetained).mapNotNull(::event)
        val before = replay(earlier)
        val retainedEvents = canonical.drop(firstRetained).filter { it.id in retainedIds }
            .mapNotNull { message -> event(message)?.let { message.id to it } }.toMap()
        val firstInitial = conversation.firstOrNull { retainedEvents[it.id]?.initial == true }
        val baseline = before ?: firstInitial?.let { replay(listOf(retainedEvents.getValue(it.id))) }

        // Old sessions, imported partial transcripts, or a new branch without a baseline start
        // a new cache epoch. Never pretend a delta is a complete prompt.
        if (baseline == null) {
            val initial = desired.checkpoint()
            return PromptTranscriptRequest(listOf(message(initial)) + conversation, initial)
        }
        val state = baseline.copyState()
        val output = mutableListOf(message(baseline.checkpoint()))
        for (item in conversation) {
            val update = retainedEvents[item.id]
            if (update != null && !(before == null && item.id == firstInitial?.id)) {
                val delta = if (update.initial) state.diff(State().apply { apply(update) }) else update
                if (delta != null) {
                    output += message(delta)
                    state.apply(delta)
                }
            }
            output += item
        }
        val delta = state.diff(desired)
        if (delta != null) output += message(delta)
        return PromptTranscriptRequest(output, delta)
    }

    /** Resolve only request-level system events; assistant metadata is inert until prepare(). */
    fun resolve(messages: List<UIMessage>, tools: List<Tool>, nativeSystem: Boolean): PromptTranscriptView {
        val transitions = messages.filter { it.role == MessageRole.SYSTEM }.mapNotNull(::event)
        val initial = transitions.firstOrNull()?.takeIf { it.initial }
        val currentTools = declarations(tools)
        if (initial == null) return PromptTranscriptView(messages, currentTools, currentTools, false, false, false)
        val state = replay(transitions) ?: State()
        // The live execution catalog remains authoritative, including after a background
        // handoff narrows the allowed tools. Historical declarations cannot grant permission.
        val correction = state.diff(state.copyState().also { next ->
            next.tools.clear()
            currentTools.forEach { next.tools[it.name] = it }
        })
        val allEvents = transitions + listOfNotNull(correction)
        val seen = linkedMapOf<String, PromptToolDeclaration>()
        var nonAdditive = false
        var redefined = false
        allEvents.forEach { update ->
            if (update.toolsRemoved.isNotEmpty()) nonAdditive = true
            update.toolsAdded.forEach { tool ->
                seen[tool.name]?.let {
                    nonAdditive = true
                    if (it != tool) redefined = true
                }
                seen[tool.name] = tool
            }
        }
        val resolved = if (nativeSystem) {
            messages + listOfNotNull(correction?.let(::message))
        } else {
            val extra = messages.filter { it.role == MessageRole.SYSTEM && event(it) == null }
            listOf(message(state.checkpoint())) + extra + messages.filter { it.role != MessageRole.SYSTEM }
        }
        return PromptTranscriptView(resolved, initial.toolsAdded, currentTools, nonAdditive, redefined, true)
    }

    fun message(event: PromptTranscriptEvent): UIMessage {
        val text = event.sections.entries.joinToString("\n\n") { (name, value) ->
            when {
                event.initial -> "<amber_section name=\"$name\">\n${value.orEmpty()}\n</amber_section>"
                value == null -> "Remove the previous system instruction section \"$name\"."
                else -> "Replace the previous system instruction section \"$name\" with:\n<amber_section name=\"$name\">\n$value\n</amber_section>"
            }
        }
        val metadata = linkedMapOf<String, kotlinx.serialization.json.JsonElement>()
        val memoryIds = event.sectionMetadata.values.flatMap {
            (it["amber_memory_record_ids"] as? JsonArray).orEmpty()
        }.distinct()
        if (memoryIds.isNotEmpty()) metadata["amber_memory_record_ids"] = JsonArray(memoryIds)
        val cacheMarkers = event.sectionMetadata.values.mapNotNull { it[SYSTEM_PROMPT_CACHE_CONTROL_METADATA] }
        (cacheMarkers.firstOrNull { it == JsonPrimitive(SYSTEM_PROMPT_CACHE_DISABLED) } ?: cacheMarkers.firstOrNull())?.let {
            metadata[SYSTEM_PROMPT_CACHE_CONTROL_METADATA] = it
        }
        return UIMessage(role = MessageRole.SYSTEM, parts = listOf(withEvent(UIMessagePart.Text(text, JsonObject(metadata)), event)))
    }

    private fun systemState(messages: List<UIMessage>): State {
        val system = messages.filter { it.role == MessageRole.SYSTEM }
        // Handoff input may already contain transitions. Ordinary fresh fragments (including
        // a guard instruction prepended before the checkpoint) override their named sections.
        val state = replay(system.mapNotNull(::event)) ?: State()
        val sections = linkedMapOf<String, MutableList<String>>()
        val metadata = linkedMapOf<String, JsonObject>()
        system.filter { event(it) == null }.forEach { message ->
            message.parts.filterIsInstance<UIMessagePart.Text>().forEach { part ->
                val name = part.metadata?.get(PROMPT_SECTION_METADATA)?.jsonPrimitive?.contentOrNull
                    ?.takeIf { it.matches(Regex("[A-Za-z0-9_-]+")) } ?: "instructions"
                if (part.text.isNotEmpty()) {
                    sections.getOrPut(name) { mutableListOf() }.add(part.text)
                    val safeMetadata = part.metadata.orEmpty().filterKeys {
                        it == "amber_memory_record_ids" || it == SYSTEM_PROMPT_CACHE_CONTROL_METADATA
                    }
                    metadata[name] = JsonObject(metadata[name].orEmpty() + safeMetadata)
                }
            }
        }
        sections.forEach { (name, text) ->
            state.sections[name] = text.joinToString("\n\n")
            state.metadata[name] = metadata.getValue(name)
        }
        return state
    }

    private fun replay(events: List<PromptTranscriptEvent>): State? {
        var state: State? = null
        events.forEach { event ->
            if (event.initial) state = State()
            state?.apply(event)
        }
        return state
    }

    private data class State(
        val sections: LinkedHashMap<String, String> = linkedMapOf(),
        val tools: LinkedHashMap<String, PromptToolDeclaration> = linkedMapOf(),
        val metadata: LinkedHashMap<String, JsonObject> = linkedMapOf(),
    ) {
        fun copyState() = State(LinkedHashMap(sections), LinkedHashMap(tools), LinkedHashMap(metadata))
        fun apply(event: PromptTranscriptEvent) {
            event.sections.forEach { (key, value) ->
                if (value == null) {
                    sections.remove(key)
                    metadata.remove(key)
                } else {
                    sections[key] = value
                    metadata[key] = event.sectionMetadata[key] ?: JsonObject(emptyMap())
                }
            }
            event.toolsRemoved.forEach(tools::remove)
            event.toolsAdded.forEach { tools[it.name] = it }
        }
        fun checkpoint() = PromptTranscriptEvent(true, sections, tools.values.toList(), sectionMetadata = metadata)
        fun diff(next: State): PromptTranscriptEvent? {
            val changed = linkedMapOf<String, String?>()
            sections.keys.filter { it !in next.sections }.forEach { changed[it] = null }
            next.sections.forEach { (key, value) ->
                if (sections[key] != value || metadata[key].orEmpty() != next.metadata[key].orEmpty()) changed[key] = value
            }
            val added = next.tools.values.filter { tools[it.name] != it }
            val removed = tools.values.filter { next.tools[it.name] != it }.map { it.name }
            return if (changed.isEmpty() && added.isEmpty() && removed.isEmpty()) null
            else PromptTranscriptEvent(sections = changed, toolsAdded = added, toolsRemoved = removed,
                sectionMetadata = next.metadata.filterKeys { it in changed })
        }
    }

    private fun withEvent(part: UIMessagePart, event: PromptTranscriptEvent): UIMessagePart {
        // Keep the persisted record opaque to UI metadata consumers. Metadata-preserving
        // Swift rewrites must still use copyTool/copyText to keep JsonObject in Kotlin.
        val metadata = JsonObject(part.metadata.orEmpty() + (PROMPT_EVENT_METADATA to JsonPrimitive(json.encodeToString(event))))
        return when (part) {
            is UIMessagePart.Text -> part.copy(metadata = metadata)
            is UIMessagePart.Reasoning -> part.copy(metadata = metadata)
            is UIMessagePart.Tool -> part.copy(metadata = metadata)
            is UIMessagePart.Image -> part.copy(metadata = metadata)
            is UIMessagePart.Video -> part.copy(metadata = metadata)
            is UIMessagePart.Audio -> part.copy(metadata = metadata)
            is UIMessagePart.Document -> part.copy(metadata = metadata)
            is UIMessagePart.MiniApp -> part.copy(metadata = metadata)
        }
    }
}
