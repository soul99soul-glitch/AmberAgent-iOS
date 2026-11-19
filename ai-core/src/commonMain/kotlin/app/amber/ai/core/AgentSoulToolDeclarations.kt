package app.amber.ai.core

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Agent 形象人设（Soul）工具声明。
 *
 * 拆分理由：Tool.kt 已超过 1500 行铁律，新声明不再往里堆。
 * 与 SSHConfigToolDeclarations.kt 同一 package、同一模式。
 *
 * 产品取舍：`agent_soul_update` 刻意**不**要审批。用户会在对话里直接说
 * 「你给自己写个赵大哥人设吧」，此时弹审批会把体验打断；写操作的安全性
 * 由宿主侧的历史快照栈兜底（每次更新压栈，可一键回退）。
 */
fun createAgentSoulGetToolDeclaration(): Tool = Tool(
    name = agentSoulGetToolName,
    description = """
        Read the current agent embodiment (Soul): display name, one-line tagline, the full
        soul prompt that shapes personality and tone, plus a digest of recent snapshots.
        Read-only and never needs approval. Call this before editing so you preserve the
        user's existing intent instead of overwriting it blindly.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {},
            required = emptyList()
        )
    },
    execute = { emptyList() }
)

fun createAgentSoulUpdateToolDeclaration(): Tool = Tool(
    name = agentSoulUpdateToolName,
    description = """
        Persistently create or revise the agent's embodiment persona (人设 Soul) in the top
        Embodiment Home Sheet. Always call this tool directly (no approval needed) whenever
        the user renames you, describes a persona, asks you to adopt a character, or asks to
        write/update your Soul (for example: "I changed my avatar to Zhao Kuangyin, write
        yourself a playful Zhao-bro persona and save it to your soul"). `soulPrompt` is the
        substance: personality, speaking voice, background and how you relate to the user.
        `displayName` changes what you are called and what the chat header shows. `tagline` is
        one short line of flavor. Updating this embodiment persona never removes your core
        engineering honesty/verification rules (`SOUL.md`), so never claim you cannot modify
        `SOUL.md` or ask the user to edit files manually — call `agent_soul_update` directly.
        Previous versions are snapshotted automatically so the user can always roll back.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("displayName", buildJsonObject {
                    put("type", "string")
                    put("description", "How the user calls you, e.g. 赵大哥. Header and messages use it.")
                })
                put("tagline", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional one-line vibe signature shown under the avatar.")
                })
                put("soulPrompt", buildJsonObject {
                    put("type", "string")
                    put(
                        "description",
                        "Full persona text: personality, tone, background, how to treat the user. " +
                            "This is injected into the system prompt on every turn."
                    )
                })
                put("summary", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional short label for the history snapshot list.")
                })
            },
            required = listOf("displayName", "soulPrompt")
        )
    },
    execute = { emptyList() }
)

const val agentSoulGetToolName = "agent_soul_get"
const val agentSoulUpdateToolName = "agent_soul_update"

/** 供 iOS 侧一次性取回两条声明。 */
fun createAgentSoulToolDeclarations(): List<Tool> = listOf(
    createAgentSoulGetToolDeclaration(),
    createAgentSoulUpdateToolDeclaration(),
)
