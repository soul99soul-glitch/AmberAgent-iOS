package app.amber.cloud.soul

import app.amber.cloud.agents.AgentMemoryPolicy
import app.amber.cloud.runtime.CloudMemoryStore
import app.amber.cloud.security.CredentialRedactor
import app.amber.cloud.security.PlaceholderCredentialException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

@Serializable
data class SoulSnapshotDto(
    val id: String,
    val displayName: String,
    val tagline: String,
    val soulMarkdown: String,
    val updatedAtMs: Long,
    val source: String,
)

@Serializable
data class SoulStateDto(
    val revision: Long = 0L,
    val updatedAtMs: Long = 0L,
    val displayName: String = CloudSoulStore.DEFAULT_DISPLAY_NAME,
    val tagline: String = "",
    val soulMarkdown: String = "",
    val isDefault: Boolean = true,
    val source: String = "default",
    val history: List<SoulSnapshotDto> = emptyList(),
)

@Serializable
data class SoulPutRequestDto(
    val displayName: String? = null,
    val tagline: String? = null,
    val soulMarkdown: String? = null,
    val isDefault: Boolean? = null,
    val updatedAtMs: Long? = null,
    val source: String? = null,
)

/**
 * Authoritative C-SOUL-V1 store for `amberd`.
 *
 * - Keeps mutable role persona (`agent_soul.json`) strictly decoupled from [IMMUTABLE_HOST_DISCIPLINE_PROMPT].
 * - Mirrors pure role persona one-way to `memory/SOUL.md` and `workspace/SOUL.md` for compatibility.
 * - Migrates customized legacy `memory/SOUL.md` on first boot without carrying over static security boilerplate.
 */
class CloudSoulStore(
    dataDir: File,
    private val memoryDir: File = File(dataDir, "memory"),
    private val workspaceDir: File? = File(dataDir, "workspace"),
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        encodeDefaults = true
    }
    private val compactJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val stateFile = File(dataDir, "agent_soul.json")
    private val memorySoulFile = File(memoryDir, "SOUL.md")
    private val workspaceSoulFile = workspaceDir?.let { File(it, "SOUL.md") }

    @Volatile
    private var cached: SoulStateDto

    init {
        dataDir.mkdirs()
        memoryDir.mkdirs()
        workspaceDir?.mkdirs()
        cached = loadOrInitialize()
    }

    fun get(): SoulStateDto = cached

    fun currentRevision(): Long = cached.revision

    @Synchronized
    fun put(request: SoulPutRequestDto, nowMs: Long = clockMs()): SoulStateDto {
        rejectPlaceholderIfPresent(request.displayName, "displayName")
        rejectPlaceholderIfPresent(request.tagline, "tagline")
        rejectPlaceholderIfPresent(request.soulMarkdown, "soulMarkdown")

        val current = cached
        val cleanSource = sanitizeSingleLine(request.source, maxChars = 48).ifEmpty { "manual" }
        val resetRequested = request.isDefault == true

        val nextDisplayName: String
        val nextTagline: String
        val nextMarkdown: String
        val nextIsDefault: Boolean

        if (resetRequested) {
            nextDisplayName = DEFAULT_DISPLAY_NAME
            nextTagline = ""
            nextMarkdown = ""
            nextIsDefault = true
        } else {
            val rawName = request.displayName?.let { sanitizeSingleLine(it, MAX_DISPLAY_NAME_CHARS) }
            nextDisplayName = rawName?.takeIf { it.isNotEmpty() } ?: current.displayName
            nextTagline = request.tagline?.let { sanitizeSingleLine(it, MAX_TAGLINE_CHARS) } ?: current.tagline
            nextMarkdown = request.soulMarkdown?.let { sanitizeMultiline(it, MAX_MARKDOWN_CHARS) } ?: current.soulMarkdown
            nextIsDefault = request.isDefault
                ?: (nextDisplayName == DEFAULT_DISPLAY_NAME && nextTagline.isEmpty() && nextMarkdown.isEmpty())
        }

        val changed = nextDisplayName != current.displayName ||
            nextTagline != current.tagline ||
            nextMarkdown != current.soulMarkdown ||
            nextIsDefault != current.isDefault

        if (!changed) return current

        val resolvedUpdatedAtMs = maxOf(nowMs, request.updatedAtMs ?: nowMs, current.updatedAtMs + 1L)
        val snapTimestamp = if (current.updatedAtMs > 0L) current.updatedAtMs else resolvedUpdatedAtMs - 1L
        val snapshot = SoulSnapshotDto(
            id = uniqueSnapshotId(snapTimestamp, current.history),
            displayName = current.displayName,
            tagline = current.tagline,
            soulMarkdown = current.soulMarkdown,
            updatedAtMs = snapTimestamp.coerceAtLeast(0L),
            source = current.source,
        )
        val updated = SoulStateDto(
            revision = current.revision + 1L,
            updatedAtMs = resolvedUpdatedAtMs,
            displayName = if (nextIsDefault) DEFAULT_DISPLAY_NAME else nextDisplayName,
            tagline = if (nextIsDefault) "" else nextTagline,
            soulMarkdown = if (nextIsDefault) "" else nextMarkdown,
            isDefault = nextIsDefault,
            source = cleanSource,
            history = (listOf(snapshot) + current.history).take(MAX_HISTORY),
        )
        persist(updated)
        return updated
    }

    fun executeToolGet(): JsonObject {
        val state = get()
        return buildJsonObject {
            put("ok", true)
            put("revision", state.revision)
            put("updatedAtMs", state.updatedAtMs)
            put("displayName", state.displayName)
            put("tagline", state.tagline)
            put("soulMarkdown", state.soulMarkdown)
            put("isDefault", state.isDefault)
            put("source", state.source)
            put("history", compactJson.encodeToJsonElement(state.history))
        }
    }

    fun executeToolUpdate(args: JsonObject, ownerAuthorized: Boolean): JsonObject {
        if (!ownerAuthorized) {
            return buildJsonObject {
                put("ok", false)
                put("error", "只有主人本人可以修改形象人设")
            }
        }
        val reset = args.boolArg("reset_to_default", "resetToDefault") ?: false
        val displayName = args.stringArg("display_name", "displayName")
        val tagline = args.stringArg("tagline")
        val soulMarkdown = args.stringArg("soul_markdown", "soulMarkdown", "soulPrompt")

        if (!reset && displayName == null && tagline == null && soulMarkdown == null) {
            return buildJsonObject {
                put("ok", false)
                put("error", "请提供 display_name、tagline、soul_markdown 之一，或设置 reset_to_default=true")
            }
        }

        val beforeRev = cached.revision
        val updated = put(
            SoulPutRequestDto(
                displayName = displayName,
                tagline = tagline,
                soulMarkdown = soulMarkdown,
                isDefault = if (reset) true else null,
                source = "chat_self_update",
            )
        )
        return buildJsonObject {
            put("ok", true)
            put("changed", updated.revision != beforeRev)
            put("revision", updated.revision)
            put("updatedAtMs", updated.updatedAtMs)
            put("displayName", updated.displayName)
            put("tagline", updated.tagline)
            put("soulMarkdown", updated.soulMarkdown)
            put("isDefault", updated.isDefault)
            put("source", updated.source)
        }
    }

    fun renderRouterSystemPrompt(routerInstructions: String): String = buildString {
        append(IMMUTABLE_HOST_DISCIPLINE_PROMPT.trim())
        append("\n\n")
        append(renderRolePersonaBlock(AgentMemoryPolicy.SHARED_WITH_GLOBAL).trim())
        append("\n\n")
        append(ROUTER_SOUL_TOOL_GUIDANCE.trim())
        append("\n\n")
        append(routerInstructions.trim())
    }

    fun renderDirectSystemPrompt(
        memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL,
        extraInstructions: String = "",
    ): String = buildString {
        append(IMMUTABLE_HOST_DISCIPLINE_PROMPT.trim())
        append("\n\n")
        append(renderRolePersonaBlock(memoryPolicy).trim())
        if (extraInstructions.isNotBlank()) {
            append("\n\n")
            append(extraInstructions.trim())
        }
    }

    fun renderRolePersonaBlock(memoryPolicy: AgentMemoryPolicy = AgentMemoryPolicy.SHARED_WITH_GLOBAL): String {
        if (memoryPolicy == AgentMemoryPolicy.HUB_ISOLATED) {
            return "你是受管独立记忆智能体，保持简洁、可靠、实事求是。"
        }
        val state = cached
        return if (state.isDefault) {
            buildString {
                append("<agent-soul is_default=\"true\" revision=\"").append(state.revision).append("\">\n")
                append("当前形象人设：你是 Amber，主人的跨端个人 AI 智能体与常驻伙伴。保持自然、简洁、可靠、实事求是。\n")
                append("</agent-soul>")
            }
        } else {
            buildString {
                append("<agent-soul is_default=\"false\" revision=\"").append(state.revision).append("\">\n")
                append("当前全端共享形象人设（请全程以此身份、称呼与口吻和主人自然交流）：\n")
                append("- 名字/自称：").append(state.displayName).append('\n')
                if (state.tagline.isNotBlank()) {
                    append("- 一句话签名：").append(state.tagline).append('\n')
                }
                if (state.soulMarkdown.isNotBlank()) {
                    append(state.soulMarkdown).append('\n')
                }
                append("</agent-soul>")
            }
        }
    }

    private fun loadOrInitialize(): SoulStateDto {
        if (stateFile.exists()) {
            runCatching {
                val loaded = json.decodeFromString<SoulStateDto>(stateFile.readText())
                mirrorToMarkdownFiles(loaded)
                return loaded
            }
        }
        val legacyText = if (memorySoulFile.exists()) memorySoulFile.readText().trim() else ""
        val defaultMirror = renderMirrorMarkdown(SoulStateDto()).trim()
        val initial = if (
            legacyText.isNotEmpty() &&
            legacyText != CloudMemoryStore.DEFAULT_SOUL_MARKDOWN.trim() &&
            legacyText != defaultMirror
        ) {
            SoulStateDto(
                revision = 1L,
                updatedAtMs = memorySoulFile.lastModified().takeIf { it > 0L } ?: clockMs(),
                displayName = DEFAULT_DISPLAY_NAME,
                tagline = "",
                soulMarkdown = sanitizeMultiline(legacyText, MAX_MARKDOWN_CHARS),
                isDefault = false,
                source = "legacy_migration",
                history = emptyList(),
            )
        } else {
            SoulStateDto()
        }
        persist(initial)
        return initial
    }

    private fun persist(state: SoulStateDto) {
        cached = state
        atomicWrite(stateFile, json.encodeToString(state))
        mirrorToMarkdownFiles(state)
    }

    private fun mirrorToMarkdownFiles(state: SoulStateDto) {
        val markdown = renderMirrorMarkdown(state)
        atomicWrite(memorySoulFile, markdown)
        workspaceSoulFile?.let { atomicWrite(it, markdown) }
    }

    private fun renderMirrorMarkdown(state: SoulStateDto): String {
        if (state.isDefault) {
            return "# 形象人设 (Amber)\n\n你是 Amber，主人的跨端个人 AI 智能体与常驻伙伴。\n"
        }
        return buildString {
            append("# 形象人设 (").append(state.displayName).append(")\n")
            if (state.tagline.isNotBlank()) {
                append('\n').append("> ").append(state.tagline).append('\n')
            }
            if (state.soulMarkdown.isNotBlank()) {
                append('\n').append(state.soulMarkdown.trim()).append('\n')
            }
        }
    }

    private fun uniqueSnapshotId(tsMs: Long, existing: List<SoulSnapshotDto>): String {
        val base = "snap_${tsMs.coerceAtLeast(0L)}"
        if (existing.none { it.id == base }) return base
        var suffix = 2
        while (existing.any { it.id == "${base}_$suffix" }) suffix++
        return "${base}_$suffix"
    }

    private fun rejectPlaceholderIfPresent(value: String?, field: String) {
        if (value != null && CredentialRedactor.isPlaceholderCredential(value)) {
            throw PlaceholderCredentialException("拒绝将占位符凭据写入形象人设字段 $field")
        }
    }

    private fun sanitizeSingleLine(raw: String?, maxChars: Int): String {
        if (raw == null) return ""
        return CredentialRedactor.redact(raw.replace(Regex("[\\r\\n]+"), " ").trim()).take(maxChars).trim()
    }

    private fun sanitizeMultiline(raw: String, maxChars: Int): String =
        CredentialRedactor.redact(raw.trim()).take(maxChars).trim()

    private fun JsonObject.stringArg(vararg keys: String): String? =
        keys.firstNotNullOfOrNull { key -> this[key]?.jsonPrimitive?.contentOrNull }

    private fun JsonObject.boolArg(vararg keys: String): Boolean? =
        keys.firstNotNullOfOrNull { key -> this[key]?.jsonPrimitive?.booleanOrNull }

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val DEFAULT_DISPLAY_NAME = "Amber"
        const val MAX_HISTORY = 8
        const val MAX_DISPLAY_NAME_CHARS = 64
        const val MAX_TAGLINE_CHARS = 200
        const val MAX_MARKDOWN_CHARS = 32_000

        const val IMMUTABLE_HOST_DISCIPLINE_PROMPT = """
<host-core-discipline>
宿主底层执行守则（系统自动保留，与角色人设互不冲突）：
- 诚实执行：凡涉及现实操作、外部查询或后台任务，必须依赖真实工具与任务回执，绝不捏造未发生的执行过程或结果。
- 凭据红线：严禁泄露、复述或回显任何密钥、令牌、密码或隐私凭据。
- 审批与沙箱边界：遵守工具域隔离；高风险操作必须等待主人在已配对且已解锁的原生 App 前台核对批准。
</host-core-discipline>
"""

        const val ROUTER_SOUL_TOOL_GUIDANCE = """
形象人设自更新规则：
- 当用户要求更换人设、性格、称呼或口吻（或要求恢复默认人设）时，你拥有且必须直接调用 `agent_soul_update` 持久更新全端共享的形象人设（更新前可按需调用 `agent_soul_get` 读取当前设定），无需派发后台 Worker。
- 底层诚实执行守则由系统自动保留，与角色扮演/性格调整互不冲突，绝不要声称无法修改 `SOUL.md`。
"""
    }
}
