package app.amber.cloud

import app.amber.ai.core.MessageRole
import app.amber.ai.core.PromptCacheWriteTier
import app.amber.ai.core.TokenUsage
import app.amber.ai.core.estimatePromptCacheInputCost
import app.amber.ai.core.sumUsage
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.runtime.CloudContextManager
import app.amber.core.context.CompactPolicy
import org.junit.Test
import java.nio.file.Files
import java.util.Locale
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 20-session desensitized long-session benchmark for Stage 2-A Clause 3:
 * - Reuses `TokenUsage.cacheCreationTokens` + `estimatePromptCacheInputCost` (5m tier, 1.25x write / 0.1x read)
 * - Reuses existing 85% compaction boundary (`CompactPolicy(precompactRatio = 0.85f, forceRatio = 0.85f)`)
 * - Covers 4 categories (5 sessions each = 20 sessions):
 *   1. Short / sparse Q&A (>5m TTL gaps or 1–3 turns)
 *   2. Continuous multi-turn tool calls (within 5m TTL)
 *   3. Long sessions crossing the 85% compaction boundary
 *   4. Explicit constraint retention across the 85% compaction boundary
 * - Does NOT enable any global default prompt-cache switch.
 */
class PromptCacheBaselineBenchmarkTest {

    private enum class Category(val label: String) {
        SHORT_OR_SPARSE("短问答/稀疏隔轮"),
        CONTINUOUS_TOOLS("连续工具调用"),
        CROSS_85_COMPACTION("跨 85% 压缩边界"),
        EXPLICIT_CONSTRAINTS("显式约束保留校验"),
    }

    private data class ConstraintNeedle(
        val label: String,
        val needle: String,
        val kind: String, // "structural_or_leading" | "buried_prose"
    )

    private data class SessionTurnSpec(
        val userText: String,
        val assistantText: String,
        val toolName: String? = null,
        val toolOutput: String? = null,
        val gapMinutesSincePrev: Double = 0.5,
    )

    private data class SessionFixture(
        val id: String,
        val category: Category,
        val title: String,
        val systemPromptTokens: Int,
        val contextWindowTokens: Int,
        val turns: List<SessionTurnSpec>,
        val expectedConstraints: List<ConstraintNeedle> = emptyList(),
    )

    private data class SessionBaselineResult(
        val fixture: SessionFixture,
        val turnCount: Int,
        val compactionCount: Int,
        val usage: TokenUsage,
        val netDeltaRatio5m: Double,
        val effectiveMultiplier5m: Double,
        val constraintsTotal: Int,
        val constraintsRetained: Int,
        val structuralTotal: Int,
        val structuralRetained: Int,
        val buriedTotal: Int,
        val buriedRetained: Int,
    )

    private fun padBlock(seed: String, approxTokens: Int): String {
        val unit = "[$seed] 脱敏上下文片段用于模拟真实对话负载与稳定前缀长度。"
        val targetChars = approxTokens * 4
        val sb = StringBuilder(targetChars + 64)
        var i = 0
        while (sb.length < targetChars) {
            sb.append(unit).append(" #").append(i++).append(' ')
        }
        return sb.toString()
    }

    private fun build20Fixtures(): List<SessionFixture> = listOf(
        // === Category 1: Short Q&A / Sparse (>5m TTL) ===
        SessionFixture(
            id = "S01", category = Category.SHORT_OR_SPARSE, title = "单轮快速事实问答",
            systemPromptTokens = 1_600, contextWindowTokens = 8_000,
            turns = listOf(
                SessionTurnSpec("解释 HTTP 409 与 403 的区别", "403 表示权限拒绝，409 表示状态冲突。", gapMinutesSincePrev = 0.0),
            ),
        ),
        SessionFixture(
            id = "S02", category = Category.SHORT_OR_SPARSE, title = "2 轮间隔 12 分钟追问（缓存过期）",
            systemPromptTokens = 1_800, contextWindowTokens = 8_000,
            turns = listOf(
                SessionTurnSpec("列出 SQLite WAL 模式注意事项", "需要同一进程共享锁并留意 checkpoint。", gapMinutesSincePrev = 0.0),
                SessionTurnSpec("那单文件备份怎么处理？", "使用 VACUUM INTO 或 online backup API。", gapMinutesSincePrev = 12.0),
            ),
        ),
        SessionFixture(
            id = "S03", category = Category.SHORT_OR_SPARSE, title = "3 轮零散问答（每轮 > 6 分钟冷写）",
            systemPromptTokens = 2_000, contextWindowTokens = 8_000,
            turns = listOf(
                SessionTurnSpec("帮我拟一条发布公告标题", "候选：v2.1 正式上线，支持离线回放。", gapMinutesSincePrev = 0.0),
                SessionTurnSpec("语气再克制一点", "候选：v2.1 更新说明：新增离线回放与稳定性改进。", gapMinutesSincePrev = 8.0),
                SessionTurnSpec("补一句英文版本", "v2.1 Release Notes: offline replay and stability fixes.", gapMinutesSincePrev = 15.0),
            ),
        ),
        SessionFixture(
            id = "S04", category = Category.SHORT_OR_SPARSE, title = "2 轮短会话（仅 1 次命中）",
            systemPromptTokens = 1_500, contextWindowTokens = 8_000,
            turns = listOf(
                SessionTurnSpec("把这段会议纪要压缩成 3 条要点：" + padBlock("s04-t1", 180), "1. 确定范围；2. 冻结接口；3. 周五联调。", gapMinutesSincePrev = 0.0),
                SessionTurnSpec("把第二条改短", "2. 接口冻结。", gapMinutesSincePrev = 1.5),
            ),
        ),
        SessionFixture(
            id = "S05", category = Category.SHORT_OR_SPARSE, title = "3 轮慢节奏审阅（1 热 1 冷）",
            systemPromptTokens = 2_200, contextWindowTokens = 8_000,
            turns = listOf(
                SessionTurnSpec("核对以下部署清单：" + padBlock("s05-t1", 220), "已检查 4 项，缺回滚脚本路径。", gapMinutesSincePrev = 0.0),
                SessionTurnSpec("补充回滚脚本 /opt/app/rollback.sh", "已记录回滚脚本路径。", gapMinutesSincePrev = 2.0),
                SessionTurnSpec("确认最终检查项", "全部检查项齐备。", gapMinutesSincePrev = 9.0),
            ),
        ),

        // === Category 2: Continuous Multi-Turn Tool Calls (hot 5m TTL) ===
        SessionFixture(
            id = "S06", category = Category.CONTINUOUS_TOOLS, title = "6 轮连续文件检索与只读排查",
            systemPromptTokens = 2_400, contextWindowTokens = 16_000,
            turns = (1..6).map { i ->
                SessionTurnSpec(
                    userText = "步骤 $i：读取模块 $i 配置并比对接口字段",
                    assistantText = "已完成模块 $i 核对，未发现字段冲突。",
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s06-tool-$i", 240),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.4,
                )
            },
        ),
        SessionFixture(
            id = "S07", category = Category.CONTINUOUS_TOOLS, title = "8 轮连续代码定位与补丁起草",
            systemPromptTokens = 2_800, contextWindowTokens = 20_000,
            turns = (1..8).map { i ->
                SessionTurnSpec(
                    userText = "第 $i 步：搜索路由测试并补齐断言",
                    assistantText = "已核查测试文件 $i，准备下一处。",
                    toolName = if (i % 2 == 0) "workspace_file_edit" else "workspace_file_search",
                    toolOutput = padBlock("s07-tool-$i", 280),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.3,
                )
            },
        ),
        SessionFixture(
            id = "S08", category = Category.CONTINUOUS_TOOLS, title = "10 轮密集诊断与日志分析",
            systemPromptTokens = 3_200, contextWindowTokens = 24_000,
            turns = (1..10).map { i ->
                SessionTurnSpec(
                    userText = "排查批次 $i 的异常日志",
                    assistantText = "批次 $i 扫描完毕，记录关键耗时指标。",
                    toolName = "history_search",
                    toolOutput = padBlock("s08-log-$i", 300),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.25,
                )
            },
        ),
        SessionFixture(
            id = "S09", category = Category.CONTINUOUS_TOOLS, title = "12 轮自动化回归与产物核验",
            systemPromptTokens = 3_000, contextWindowTokens = 28_000,
            turns = (1..12).map { i ->
                SessionTurnSpec(
                    userText = "核验用例组 $i 执行结果",
                    assistantText = "用例组 $i 全部通过。",
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s09-case-$i", 260),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.35,
                )
            },
        ),
        SessionFixture(
            id = "S10", category = Category.CONTINUOUS_TOOLS, title = "9 轮含一次 7 分钟人工确认停顿",
            systemPromptTokens = 2_600, contextWindowTokens = 20_000,
            turns = (1..9).map { i ->
                SessionTurnSpec(
                    userText = "推进工具链步骤 $i",
                    assistantText = "步骤 $i 执行完成。",
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s10-step-$i", 250),
                    gapMinutesSincePrev = when (i) {
                        1 -> 0.0
                        5 -> 7.0 // Simulates user pausing >5m during an approval
                        else -> 0.4
                    },
                )
            },
        ),

        // === Category 3: Crossing 85% Compaction Boundary ===
        SessionFixture(
            id = "S11", category = Category.CROSS_85_COMPACTION, title = "单次跨 85% 压缩后继续 4 轮热读取",
            systemPromptTokens = 1_200, contextWindowTokens = 4_800,
            turns = (1..12).map { i ->
                SessionTurnSpec(
                    userText = "长任务阶段 $i：" + padBlock("s11-u-$i", 160),
                    assistantText = "阶段 $i 结论：" + padBlock("s11-a-$i", 160),
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s11-t-$i", 120),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.4,
                )
            },
        ),
        SessionFixture(
            id = "S12", category = Category.CROSS_85_COMPACTION, title = "连续两次跨 85% 压缩（重度长会话）",
            systemPromptTokens = 1_200, contextWindowTokens = 4_500,
            turns = (1..16).map { i ->
                SessionTurnSpec(
                    userText = "深度审计第 $i 轮：" + padBlock("s12-u-$i", 180),
                    assistantText = "第 $i 轮审计摘要：" + padBlock("s12-a-$i", 180),
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s12-t-$i", 140),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.4,
                )
            },
        ),
        SessionFixture(
            id = "S13", category = Category.CROSS_85_COMPACTION, title = "跨 85% 压缩且压缩后立刻进入稀疏间隔",
            systemPromptTokens = 1_200, contextWindowTokens = 4_800,
            turns = (1..10).map { i ->
                SessionTurnSpec(
                    userText = "设计迭代 $i：" + padBlock("s13-u-$i", 190),
                    assistantText = "迭代 $i 变更：" + padBlock("s13-a-$i", 190),
                    gapMinutesSincePrev = if (i == 1) 0.0 else if (i >= 8) 6.5 else 0.5,
                )
            },
        ),
        SessionFixture(
            id = "S14", category = Category.CROSS_85_COMPACTION, title = "大工具输出触发 85% 压缩后再密集追问",
            systemPromptTokens = 1_400, contextWindowTokens = 5_200,
            turns = (1..13).map { i ->
                SessionTurnSpec(
                    userText = "分析构建日志批次 $i：" + padBlock("s14-u-$i", 120),
                    assistantText = "日志批次 $i 已归档。",
                    toolName = "workspace_file_read",
                    toolOutput = padBlock("s14-log-$i", 260),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.3,
                )
            },
        ),
        SessionFixture(
            id = "S15", category = Category.CROSS_85_COMPACTION, title = "刚好越过 85% 边界的紧凑多轮会话",
            systemPromptTokens = 1_000, contextWindowTokens = 4_400,
            turns = (1..11).map { i ->
                SessionTurnSpec(
                    userText = "合同比对第 $i 节：" + padBlock("s15-u-$i", 165),
                    assistantText = "第 $i 节差异已标注：" + padBlock("s15-a-$i", 165),
                    gapMinutesSincePrev = if (i == 1) 0.0 else 0.45,
                )
            },
        ),

        // === Category 4: Explicit Constraint Retention Across 85% Compaction ===
        SessionFixture(
            id = "S16", category = Category.EXPLICIT_CONSTRAINTS, title = "路径与错误码显式约束保留",
            systemPromptTokens = 1_000, contextWindowTokens = 4_400,
            turns = listOf(
                SessionTurnSpec(
                    userText = "必须仅修改 /etc/amber/policy.yaml，且遇到 exit code 137 立即中止。\n" + padBlock("s16-t1", 170),
                    assistantText = "已记住约束：仅改 /etc/amber/policy.yaml，遇 exit code 137 中止。",
                    gapMinutesSincePrev = 0.0,
                ),
            ) + (2..11).map { i ->
                SessionTurnSpec(
                    userText = "继续核查第 $i 个配置项：" + padBlock("s16-u-$i", 175),
                    assistantText = "配置项 $i 核查完成：" + padBlock("s16-a-$i", 175),
                    gapMinutesSincePrev = 0.4,
                )
            },
            expectedConstraints = listOf(
                ConstraintNeedle("配置文件路径", "/etc/amber/policy.yaml", "structural_or_leading"),
                ConstraintNeedle("中止退出码", "exit code 137", "structural_or_leading"),
            ),
        ),
        SessionFixture(
            id = "S17", category = Category.EXPLICIT_CONSTRAINTS, title = "Commit SHA 与首句硬规则保留",
            systemPromptTokens = 1_000, contextWindowTokens = 4_400,
            turns = listOf(
                SessionTurnSpec(
                    userText = "严禁回滚提交 a343f4ea，且输出必须保持 UTC ISO-8601。\n" + padBlock("s17-t1", 170),
                    assistantText = "已确认保留基线提交 a343f4ea 与 UTC ISO-8601 格式。",
                    gapMinutesSincePrev = 0.0,
                ),
            ) + (2..11).map { i ->
                SessionTurnSpec(
                    userText = "对比变更集 $i：" + padBlock("s17-u-$i", 175),
                    assistantText = "变更集 $i 校验通过：" + padBlock("s17-a-$i", 175),
                    gapMinutesSincePrev = 0.4,
                )
            },
            expectedConstraints = listOf(
                ConstraintNeedle("基线 Commit SHA", "a343f4ea", "structural_or_leading"),
                ConstraintNeedle("首句时间格式规则", "UTC ISO-8601", "structural_or_leading"),
            ),
        ),
        SessionFixture(
            id = "S18", category = Category.EXPLICIT_CONSTRAINTS, title = "长段落末尾纯自然语言约束（测试压缩盲区）",
            systemPromptTokens = 1_000, contextWindowTokens = 4_400,
            turns = listOf(
                SessionTurnSpec(
                    userText = padBlock("s18-bg", 170) + "\n补充要求：对外周报正文不要出现任何英文缩写，也不要使用感叹号。",
                    assistantText = "明白，会按上述风格撰写。",
                    gapMinutesSincePrev = 0.0,
                ),
            ) + (2..11).map { i ->
                SessionTurnSpec(
                    userText = "追加第 $i 条业务进展：" + padBlock("s18-u-$i", 175),
                    assistantText = "第 $i 条进展已整理：" + padBlock("s18-a-$i", 175),
                    gapMinutesSincePrev = 0.4,
                )
            },
            expectedConstraints = listOf(
                ConstraintNeedle("段末纯文本禁令(英文缩写)", "不要出现任何英文缩写", "buried_prose"),
                ConstraintNeedle("段末纯文本禁令(感叹号)", "不要使用感叹号", "buried_prose"),
            ),
        ),
        SessionFixture(
            id = "S19", category = Category.EXPLICIT_CONSTRAINTS, title = "混合约束（前置规则 + 错误栈 + 段末语气要求）",
            systemPromptTokens = 1_000, contextWindowTokens = 4_600,
            turns = listOf(
                SessionTurnSpec(
                    userText = "输出仅限简体中文表格。\n" + padBlock("s19-mid", 160) + "\nError: timeout on /var/run/amber.sock\n末尾补充：金额全部四舍五入到整数元。",
                    assistantText = "已收到全部输出要求与异常路径。",
                    gapMinutesSincePrev = 0.0,
                ),
            ) + (2..12).map { i ->
                SessionTurnSpec(
                    userText = "汇总账单批次 $i：" + padBlock("s19-u-$i", 175),
                    assistantText = "批次 $i 汇总完成：" + padBlock("s19-a-$i", 175),
                    gapMinutesSincePrev = 0.35,
                )
            },
            expectedConstraints = listOf(
                ConstraintNeedle("首句输出格式", "仅限简体中文表格", "structural_or_leading"),
                ConstraintNeedle("异常 Socket 路径", "/var/run/amber.sock", "structural_or_leading"),
                ConstraintNeedle("段末舍入规则", "四舍五入到整数元", "buried_prose"),
            ),
        ),
        SessionFixture(
            id = "S20", category = Category.EXPLICIT_CONSTRAINTS, title = "多轮分散约束跨 85% 边界校验",
            systemPromptTokens = 1_000, contextWindowTokens = 4_600,
            turns = listOf(
                SessionTurnSpec(
                    userText = "红线：只读检查 /srv/deploy/release.json，绝不自动推送远端。\n" + padBlock("s20-t1", 160),
                    assistantText = "收到，不推远端，只读检查 /srv/deploy/release.json。",
                    gapMinutesSincePrev = 0.0,
                ),
                SessionTurnSpec(
                    userText = "第二条约束：预算上限 500 美元，超额先停。\n" + padBlock("s20-t2", 160),
                    assistantText = "已记录预算红线 500 美元。",
                    gapMinutesSincePrev = 0.4,
                ),
            ) + (3..12).map { i ->
                SessionTurnSpec(
                    userText = "检查子项 $i：" + padBlock("s20-u-$i", 175),
                    assistantText = "子项 $i 正常：" + padBlock("s20-a-$i", 175),
                    gapMinutesSincePrev = 0.4,
                )
            },
            expectedConstraints = listOf(
                ConstraintNeedle("发布清单路径", "/srv/deploy/release.json", "structural_or_leading"),
                ConstraintNeedle("首句不推送红线", "绝不自动推送远端", "structural_or_leading"),
                ConstraintNeedle("首句预算上限", "预算上限 500 美元", "structural_or_leading"),
            ),
        ),
    )

    private fun runFixture(fixture: SessionFixture): SessionBaselineResult {
        val dir = Files.createTempDirectory("cache-baseline-${fixture.id}-").toFile()
        dir.deleteOnExit()
        val policy = CompactPolicy(
            enabled = true,
            precompactRatio = 0.85f,
            forceRatio = 0.85f,
            keepRecentTurns = 4,
        )
        val contextManager = CloudContextManager(checkpointsDir = dir, policy = policy, minDeltaMessages = 4)
        val systemPrompt = padBlock("sys-${fixture.id}", fixture.systemPromptTokens)
        val history = mutableListOf<UIMessage>()
        val perTurnUsages = mutableListOf<TokenUsage>()

        var cachedPrefixFingerprint: List<String> = emptyList()
        var cachedPrefixTokens = 0
        var compactionCount = 0
        var lastProjectedMessages: List<UIMessage> = emptyList()

        for ((idx, turn) in fixture.turns.withIndex()) {
            history += UIMessage.user(turn.userText)
            val compactRes = contextManager.compactIfNeeded(
                conversationId = fixture.id,
                messages = listOf(UIMessage.system(systemPrompt)) + history,
                contextWindowTokens = fixture.contextWindowTokens,
            )
            if (!compactRes.status.startsWith("skipped:")) {
                compactionCount += 1
            }

            val projected = contextManager.prepareRequestMessages(
                systemPrompt = systemPrompt,
                memories = emptyList(),
                conversationId = fixture.id,
                historyMessages = history,
                tokenBudget = fixture.contextWindowTokens,
            )
            lastProjectedMessages = projected

            val totalPromptTokens = contextManager.estimateTokens(projected)
            val currentPrefixMsgs = if (projected.size > 1) projected.dropLast(1) else projected
            val currentPrefixFingerprint = currentPrefixMsgs.map { "${it.role}:${it.toText().hashCode()}" }
            val currentPrefixTokens = contextManager.estimateTokens(currentPrefixMsgs)

            val ttlAlive = idx > 0 && turn.gapMinutesSincePrev <= 5.0
            val prefixStillMatches = ttlAlive &&
                cachedPrefixFingerprint.isNotEmpty() &&
                currentPrefixFingerprint.size >= cachedPrefixFingerprint.size &&
                currentPrefixFingerprint.take(cachedPrefixFingerprint.size) == cachedPrefixFingerprint

            val cacheReadTokens: Int
            val cacheWriteTokens: Int
            val uncachedTokens: Int
            if (prefixStillMatches) {
                cacheReadTokens = cachedPrefixTokens.coerceAtMost(totalPromptTokens)
                val newPrefixGrowth = (currentPrefixTokens - cachedPrefixTokens).coerceAtLeast(0)
                // Claude incremental ephemeral cache writes new prefix delta when >= 128 tokens; rest is uncached tail
                cacheWriteTokens = newPrefixGrowth.coerceAtMost(totalPromptTokens - cacheReadTokens)
                uncachedTokens = (totalPromptTokens - cacheReadTokens - cacheWriteTokens).coerceAtLeast(0)
            } else {
                cacheReadTokens = 0
                cacheWriteTokens = currentPrefixTokens.coerceAtMost(totalPromptTokens)
                uncachedTokens = (totalPromptTokens - cacheWriteTokens).coerceAtLeast(0)
            }

            // Update cache state for next turn
            cachedPrefixFingerprint = currentPrefixFingerprint
            cachedPrefixTokens = currentPrefixTokens

            val completionTokens = contextManager.estimateTokens(UIMessage.assistant(turn.assistantText))
            perTurnUsages += TokenUsage(
                promptTokens = totalPromptTokens,
                completionTokens = completionTokens,
                cachedTokens = cacheReadTokens,
                totalTokens = totalPromptTokens + completionTokens,
                cacheCreationTokens = cacheWriteTokens,
            )

            // Append assistant response (and optional tool part) to stored history
            val parts = buildList<UIMessagePart> {
                if (turn.toolName != null) {
                    add(
                        UIMessagePart.Tool(
                            toolCallId = "${fixture.id}-call-$idx",
                            toolName = turn.toolName,
                            input = """{"step":$idx}""",
                            output = listOf(UIMessagePart.Text(turn.toolOutput.orEmpty())),
                        )
                    )
                }
                add(UIMessagePart.Text(turn.assistantText))
            }
            history += UIMessage(role = MessageRole.ASSISTANT, parts = parts)
        }

        val aggregated = perTurnUsages.sumUsage()
        val estimate5m = aggregated.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M)

        val finalPromptText = lastProjectedMessages.joinToString("\n") { it.toText() }
        val structural = fixture.expectedConstraints.filter { it.kind == "structural_or_leading" }
        val buried = fixture.expectedConstraints.filter { it.kind == "buried_prose" }
        val retainedStructural = structural.count { finalPromptText.contains(it.needle) }
        val retainedBuried = buried.count { finalPromptText.contains(it.needle) }

        return SessionBaselineResult(
            fixture = fixture,
            turnCount = fixture.turns.size,
            compactionCount = compactionCount,
            usage = aggregated,
            netDeltaRatio5m = estimate5m.netDeltaRatio,
            effectiveMultiplier5m = estimate5m.effectiveMultiplier,
            constraintsTotal = fixture.expectedConstraints.size,
            constraintsRetained = retainedStructural + retainedBuried,
            structuralTotal = structural.size,
            structuralRetained = retainedStructural,
            buriedTotal = buried.size,
            buriedRetained = retainedBuried,
        )
    }

    @Test
    fun run20DesensitizedLongSessionCacheAndCompactionBaseline() {
        val fixtures = build20Fixtures()
        assertEquals(20, fixtures.size, "Baseline must cover exactly 20 desensitized sessions")

        val results = fixtures.map(::runFixture)

        // Verify per-category structural expectations
        val shortSparse = results.filter { it.fixture.category == Category.SHORT_OR_SPARSE }
        val continuousTools = results.filter { it.fixture.category == Category.CONTINUOUS_TOOLS }
        val crossCompaction = results.filter { it.fixture.category == Category.CROSS_85_COMPACTION }
        val explicitConstraints = results.filter { it.fixture.category == Category.EXPLICIT_CONSTRAINTS }

        assertEquals(5, shortSparse.size)
        assertEquals(5, continuousTools.size)
        assertEquals(5, crossCompaction.size)
        assertEquals(5, explicitConstraints.size)

        // Short/sparse sessions suffer net overhead under 5m ephemeral caching (justifying NOT enabling global default)
        assertTrue(
            shortSparse.map { it.usage }.sumUsage().estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M).netDeltaRatio > 0.0,
            "Short/sparse sessions should show positive net cost overhead under 5m cache",
        )
        // Continuous multi-turn tool sessions achieve clear net savings under 5m cache
        assertTrue(
            continuousTools.map { it.usage }.sumUsage().estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M).netDeltaRatio < -0.35,
            "Continuous tool sessions should achieve >35% net savings under 5m cache",
        )
        // Every cross-85% and explicit-constraint session actually triggered 85% compaction
        assertTrue(crossCompaction.all { it.compactionCount >= 1 }, "All cross-85% sessions must trigger compaction")
        assertTrue(explicitConstraints.all { it.compactionCount >= 1 }, "All explicit-constraint sessions must cross 85% compaction")
        // Structural / leading constraints must have 100% retention
        assertEquals(
            explicitConstraints.sumOf { it.structuralTotal },
            explicitConstraints.sumOf { it.structuralRetained },
            "All structural/leading explicit constraints must survive 85% compaction",
        )

        // Print deterministic summary table for baseline report verification
        println("=== STAGE2_CACHE_BASELINE_BEGIN ===")
        for (r in results) {
            val pct = String.format(Locale.US, "%+.1f%%", r.netDeltaRatio5m * 100.0)
            val mult = String.format(Locale.US, "%.3fx", r.effectiveMultiplier5m)
            val cons = if (r.constraintsTotal > 0) "${r.constraintsRetained}/${r.constraintsTotal}" else "-"
            println(
                "${r.fixture.id}|${r.fixture.category.label}|${r.fixture.title}|turns=${r.turnCount}|compacts=${r.compactionCount}|" +
                    "prompt=${r.usage.promptTokens}|read=${r.usage.cachedTokens}|write=${r.usage.cacheCreationTokens}|uncached=${r.usage.uncachedInputTokens}|" +
                    "delta5m=$pct|mult5m=$mult|constraints=$cons"
            )
        }
        println("--- CATEGORY_SUMMARY ---")
        for (cat in Category.entries) {
            val group = results.filter { it.fixture.category == cat }
            val sum = group.map { it.usage }.sumUsage()
            val est = sum.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M)
            val pct = String.format(Locale.US, "%+.1f%%", est.netDeltaRatio * 100.0)
            val cTotal = group.sumOf { it.constraintsTotal }
            val cRetained = group.sumOf { it.constraintsRetained }
            val sTotal = group.sumOf { it.structuralTotal }
            val sRetained = group.sumOf { it.structuralRetained }
            val bTotal = group.sumOf { it.buriedTotal }
            val bRetained = group.sumOf { it.buriedRetained }
            println(
                "CAT|${cat.label}|sessions=${group.size}|compacts=${group.sumOf { it.compactionCount }}|" +
                    "prompt=${sum.promptTokens}|read=${sum.cachedTokens}|write=${sum.cacheCreationTokens}|uncached=${sum.uncachedInputTokens}|" +
                    "delta5m=$pct|mult5m=${String.format(Locale.US, "%.3fx", est.effectiveMultiplier)}|" +
                    "constraints=$cRetained/$cTotal|structural=$sRetained/$sTotal|buried=$bRetained/$bTotal"
            )
        }
        val overallSum = results.map { it.usage }.sumUsage()
        val overallEst = overallSum.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_5M)
        println(
            "ALL|20_SESSIONS|compacts=${results.sumOf { it.compactionCount }}|" +
                "prompt=${overallSum.promptTokens}|read=${overallSum.cachedTokens}|write=${overallSum.cacheCreationTokens}|uncached=${overallSum.uncachedInputTokens}|" +
                "delta5m=${String.format(Locale.US, "%+.1f%%", overallEst.netDeltaRatio * 100.0)}|mult5m=${String.format(Locale.US, "%.3fx", overallEst.effectiveMultiplier)}"
        )
        println("=== STAGE2_CACHE_BASELINE_END ===")
    }
}
