package app.amber.cloud.orchestration

import app.amber.cloud.channel.SenderRole
import app.amber.cloud.runtime.ExecutionScope
import app.amber.core.native.AmberNativeBridge
import kotlinx.serialization.Serializable
import java.nio.charset.StandardCharsets

// ============================================================================
// 0. 编排内核配置与校验 (遵守用户拍板决策 #2 & #5)
// ============================================================================

@Serializable
data class OrchestrationConfig(
    /** 并发 Worker 槽位：默认 3，可配置范围 3..8（超出范围校验报错） */
    val maxConcurrentWorkers: Int = 3,
    /** 任务创建后 3 分钟仍未进入 WORKING 则判定为 never-started */
    val neverStartedTimeoutMs: Long = 3 * 60_000L,
    /** 处于 WAITING（等待审批或输入）超过 5 分钟进入巡检预警 */
    val approvalStuckTimeoutMs: Long = 5 * 60_000L,
    /** WORKING 状态下 10 分钟无进展触发温和催促 (Step 1 Nudge) */
    val runningQuietNudgeMs: Long = 10 * 60_000L,
    /** 催促后再静默 5 分钟触发中断重派 (Step 2 Interrupt & Redeliver) */
    val recoveryRedeliverDelayMs: Long = 5 * 60_000L,
    /** 长耗时构建工具（如 xcodebuild、gradlew）在 45 分钟内豁免静默打断 */
    val longToolExemptionMs: Long = 45 * 60_000L,
    /** 节点或 Provider 断连宽限期：90 秒 */
    val disconnectGraceMs: Long = 90_000L,
    /** 单个任务最大自愈次数：最多 2 次 */
    val maxRecoveryAttempts: Int = 2,
    /** 派给离线 PairedMacNode 的任务在 QUEUED 最多保留 24 小时 */
    val macOfflineQueueTtlMs: Long = 24 * 60 * 60_000L,
    /** BatchRollup 唤醒锁 TTL：10 分钟 */
    val wakeClaimTtlMs: Long = 10 * 60_000L,
    /** Router 在 IM 单次回复最大词数：100 词（超出自动归档并附上引用） */
    val routerMaxReplyWords: Int = 100,
    /** 外部模型驱动的 Watchdog 开关（默认关闭，开启时调用 CloudWatchdogJudge） */
    val modelWatchdogEnabled: Boolean = false,
    /** 享受 45 分钟长耗时豁免的工具名称集合 */
    val longRunningToolNames: Set<String> = DEFAULT_LONG_RUNNING_TOOLS,
) {
    init {
        require(maxConcurrentWorkers in 3..8) {
            "并发 Worker 槽位 (maxConcurrentWorkers) 必须在 3..8 之间，当前配置为: $maxConcurrentWorkers"
        }
        require(maxRecoveryAttempts >= 1) {
            "maxRecoveryAttempts 必须 >= 1"
        }
    }

    fun isExemptLongRunningTool(toolName: String?): Boolean {
        if (toolName.isNullOrBlank()) return false
        val normalized = toolName.trim().lowercase()
        return longRunningToolNames.any { candidate ->
            val clean = candidate.lowercase()
            normalized == clean || normalized.contains(clean)
        }
    }

    companion object {
        val DEFAULT_LONG_RUNNING_TOOLS = setOf(
            "xcodebuild",
            "gradlew",
            "./gradlew",
            "gradle",
            "cargo_build",
            "docker_build",
            "swift_test",
            "long_build",
        )
    }
}

// ============================================================================
// 1. 主体身份与权限矩阵 (CloudPrincipal)
// ============================================================================

@Serializable
sealed class CloudPrincipal {
    abstract val principalId: String
    abstract val executionScope: ExecutionScope

    /** 已绑定并验签的主人（来自四端已解锁前台或已绑定飞书/Telegram 私聊） */
    @Serializable
    data class OwnerUser(
        override val principalId: String,
        val channelId: String,
        val trustedForegroundApp: Boolean = false,
    ) : CloudPrincipal() {
        override val executionScope: ExecutionScope = ExecutionScope.MAIN_AGENT
    }

    /** 云端本体常驻 Router / Coordinator（主时间线 PRIMARY_CONVERSATION_ID） */
    @Serializable
    data class CloudCoordinator(
        override val principalId: String = "coordinator:main",
        val activeSessionId: String,
        val activeTurnId: String,
    ) : CloudPrincipal() {
        override val executionScope: ExecutionScope = ExecutionScope.MAIN_AGENT
    }

    /** 受控 Worker（云端子智能体、反连 Mac 节点、远程沙箱） */
    @Serializable
    data class Worker(
        override val principalId: String,
        val workItemId: String,
        val batchId: String,
        val targetNode: ExecutionTargetNode,
        override val executionScope: ExecutionScope = ExecutionScope.SUBAGENT,
    ) : CloudPrincipal()

    /** 自动化单轮执行器（严格绑定单次 runId，权限不跨轮延续） */
    @Serializable
    data class AutomationRunner(
        override val principalId: String,
        val automationId: String,
        val runId: String,
        val iteration: Int,
        override val executionScope: ExecutionScope = ExecutionScope.MAIN_AGENT,
    ) : CloudPrincipal()

    /** 非主人外部发送者（访客、群协作者或未授权调用方） */
    @Serializable
    data class ExternalCaller(
        override val principalId: String,
        val channelId: String,
        val senderRole: SenderRole = SenderRole.GUEST,
        override val executionScope: ExecutionScope = ExecutionScope.SUBAGENT,
    ) : CloudPrincipal()
}

/**
 * 跨端异构执行目标节点。
 */
@Serializable
sealed class ExecutionTargetNode {
    /** 云端内生只读/受限子会话 (ExecutionScope.SUBAGENT) */
    @Serializable
    data class CloudSubagent(
        val rolePrompt: String,
        val modelInstanceId: String? = null,
    ) : ExecutionTargetNode()

    /** 通过 Gateway 配对的家用/办公桌面 Mac 节点 */
    @Serializable
    data class PairedMacNode(
        val deviceId: String,
        val requiredCapabilities: Set<String> = emptySet(),
    ) : ExecutionTargetNode()

    /** 云端受控容器或预置 SSH 远程沙箱 */
    @Serializable
    data class RemoteSandbox(
        val sshProfileId: String? = null,
        val timeoutSeconds: Int = 1800,
    ) : ExecutionTargetNode()
}

// ============================================================================
// 2. 原始人类消息溯源与 8 态持久化任务模型
// ============================================================================

@Serializable
enum class MessageProvenanceOrigin {
    OWNER_HUMAN,
    COLLABORATOR_HUMAN,
    GUEST_HUMAN,
    AGENT,
    AUTOMATION,
}

/**
 * 服务端从持久层解析的原始消息溯源快照。
 * 任何新任务都必须追溯到至少一条 [origin] == [MessageProvenanceOrigin.OWNER_HUMAN] 且 [senderRole] == [SenderRole.OWNER] 的真实主人消息。
 */
@Serializable
data class SourceMessageProvenance(
    val sessionId: String,
    val messageId: String,
    val senderId: String,
    val channelId: String,
    val senderRole: SenderRole = SenderRole.OWNER,
    val origin: MessageProvenanceOrigin = MessageProvenanceOrigin.OWNER_HUMAN,
    val rawTextHash: String,
    val createdAtEpochMs: Long,
) {
    val canAuthorizeNewWork: Boolean
        get() = senderRole == SenderRole.OWNER && origin == MessageProvenanceOrigin.OWNER_HUMAN
}

/**
 * 8 态任务生命周期。
 */
@Serializable
enum class WorkItemState {
    QUEUED,     // 排队等待并发槽位或等待离线 Mac 上线 (slotHeld = false)
    STARTING,   // 已占槽，正在唤醒节点或初始化会话 (slotHeld = true)
    WORKING,    // 正在执行 Turn 或长耗时工具 (slotHeld = true)
    WAITING,    // 等待前台 App 高危审批或补充输入 (slotHeld = true)
    IDLE,       // 单轮结束但尚未汇报终态 (slotHeld = false)
    COMPLETED,  // 成功完成并产出结算报告 (终态, slotHeld = false)
    FAILED,     // 执行失败、自愈耗尽或离线超 24h (终态, slotHeld = false)
    CANCELLED;  // 被主人或 Coordinator 主动取消 (终态, slotHeld = false)

    val isTerminal: Boolean
        get() = this == COMPLETED || this == FAILED || this == CANCELLED

    val holdsConcurrencySlot: Boolean
        get() = this == STARTING || this == WORKING || this == WAITING
}

@Serializable
enum class RecoveryStage {
    NONE,
    NUDGED,
    REDELIVERED,
    EXHAUSTED,
}

@Serializable
data class WorkItemSubmissionSpec(
    /** 逻辑任务幂等键（正则 [a-z0-9._:-]{1,128}） */
    val taskKey: String,
    val title: String,
    val brief: String,
    val targetNode: ExecutionTargetNode,
    val expectedOutputSchemaHint: String? = null,
    /** 任务初始订阅的 Thread Key 列表（用于同一话题/PR/任务的后续消息直通） */
    val subscribedThreadKeys: List<String> = emptyList(),
) {
    init {
        require(TASK_KEY_REGEX.matches(taskKey)) {
            "taskKey 必须匹配 [a-z0-9._:-]{1,128}: $taskKey"
        }
    }

    companion object {
        val TASK_KEY_REGEX = Regex("^[a-zA-Z0-9._:-]{1,128}$")
    }
}

@Serializable
data class CloudWorkItemRecord(
    /** 确定性主键："work:" + sha256(coordinatorSessionId + scopeKey + taskKey) */
    val workItemId: String,
    val batchId: String,
    val scopeKey: String,
    val taskKey: String,
    /** 任务实质内容 SHA-256 指纹，用于区分“幂等重放”与“同键篡改冲突” */
    val taskFingerprint: String,
    val title: String,
    val brief: String,
    val targetNode: ExecutionTargetNode,
    val expectedOutputSchemaHint: String? = null,
    val workerSessionId: String?,
    val state: WorkItemState,
    val slotHeld: Boolean,
    val progressRevision: Int = 0,
    val latestProgressNote: String? = null,
    val activeToolName: String? = null,
    val activeToolStartedAtMs: Long? = null,
    val recoveriesUsed: Int = 0,
    val recoveryStage: RecoveryStage = RecoveryStage.NONE,
    val lastNudgedAtMs: Long? = null,
    val waitingStartedAtMs: Long? = null,
    val disconnectedSinceMs: Long? = null,
    val startedAtMs: Long? = null,
    val lastActivityAtMs: Long,
    val sourceProvenance: List<SourceMessageProvenance>,
    val subscribedThreadKeys: List<String> = emptyList(),
    val settlementReportPath: String? = null,
    val failureReason: String? = null,
    val needsYouEscalated: Boolean = false,
    val createdAtMs: Long,
    val updatedAtMs: Long,
)

@Serializable
data class WorkerSettlementReport(
    val workItemId: String,
    val outcome: String, // "completed" | "failed" | "blocked"
    val summary: String,
    val blockers: List<String> = emptyList(),
    val artifacts: List<String> = emptyList(),
    /** 刻意不含动态生成时间戳，确保内容哈希稳定去重 */
    val contentSha256: String = OrchestrationHash.sha256Hex(
        buildString {
            append(workItemId).append('\n')
            append(outcome.trim().lowercase()).append('\n')
            append(summary.trim()).append('\n')
            append(blockers.joinToString("\n")).append('\n')
            append(artifacts.joinToString("\n"))
        }
    ),
)

@Serializable
data class BatchSubmissionResult(
    val batchId: String,
    val items: List<CloudWorkItemRecord>,
    val replayedWorkItemIds: Set<String>,
)

@Serializable
data class BatchRollupRecord(
    val batchId: String,
    val workItemIds: List<String>,
    val rollupMarkdown: String,
    val wakeClaimId: String,
    val claimedAtMs: Long,
    val deliveredToRouter: Boolean = false,
)

// ============================================================================
// 3. 链式召回 (Chain of Recall)、双层无损读取与取证级诊断模型
// ============================================================================

@Serializable
enum class RecallObjectKind {
    TRIGGER_MESSAGE,
    THREAD,
    WORK_ITEM,
    WORKER_SESSION,
    ARCHIVE_DOCUMENT,
    BATCH,
}

/**
 * 链式召回（Chain of Recall）下一跳内联引用摘要。
 */
@Serializable
data class RecallLink(
    val kind: RecallObjectKind,
    val id: String,
    val summary: String,
)

/**
 * 遵循 Inline & Spill 的链式召回节点快照。
 */
@Serializable
data class RecallNodeSnapshot(
    val kind: RecallObjectKind,
    val id: String,
    val title: String,
    val inlineText: String,
    val spilled: Boolean,
    val spillReference: String? = null,
    val nextHops: List<RecallLink> = emptyList(),
)

@Serializable
data class MessagePreviewItem(
    val messageIndex: Int,
    val messageId: String,
    val role: String,
    val previewText: String,
    val truncated: Boolean,
    val totalChars: Int,
    /** 格式："${updatedAtMs}:${totalChars}"，用于单条长消息切片读取时的防撕裂校验 */
    val messageVersion: String,
    val streaming: Boolean = false,
    val nextHopLinks: List<RecallLink> = emptyList(),
)

@Serializable
data class SessionReadPage(
    val sessionId: String,
    val workItemId: String? = null,
    val derivedStatus: String, // waiting-for-approval > waiting-for-input > working > error > idle
    val items: List<MessagePreviewItem>,
    val nextPageCursor: String?,
    val nextHopLinks: List<RecallLink> = emptyList(),
)

@Serializable
data class MessageSliceCursor(
    val sessionId: String,
    val messageIndex: Int,
    val messageId: String,
    val messageVersion: String,
    val offsetChars: Int,
    val limitChars: Int = 4_000,
)

@Serializable
data class MessageSliceResult(
    val sessionId: String,
    val messageId: String,
    val messageVersion: String,
    val sliceText: String,
    val nextOffsetChars: Int?,
    val nextHopLinks: List<RecallLink> = emptyList(),
)

@Serializable
data class DiagnosticEventEntry(
    val sequence: Long,
    val sessionId: String,
    val workItemId: String? = null,
    val kind: String,
    val messageId: String? = null,
    val detail: String,
    val timestampMs: Long,
)

@Serializable
data class SessionDiagnosticSnapshot(
    val sessionId: String,
    val workItemId: String?,
    val derivedStatus: String,
    /** 结构化异常发现：如 "remote_node_disconnected", "approval_wait_timeout", "tool_overtime", "never_started", "running_quiet", "recovery_exhausted" */
    val findings: List<String>,
    val recentCollapsedEvents: List<String>,
    /** 显式声明日志覆盖度：区分 SQLite 完整持久层与内存 RingBuffer ("absence is not proof") */
    val coverageNote: String,
    val sqliteEventCount: Int = 0,
    val ringBufferEventCount: Int = 0,
    val nextHopLinks: List<RecallLink> = emptyList(),
)

// ============================================================================
// 4. SQLite 乐观锁 + SHA-256 文档归档模型 (不引入 Git)
// ============================================================================

@Serializable
data class ArchivedDocumentRecord(
    val docPath: String,
    val ownerKind: String,
    val ownerId: String,
    val revision: Int,
    val contentSha256: String,
    val sizeBytes: Int,
    val updatedAtMs: Long,
    val absoluteFilePath: String,
    val replayedUnchanged: Boolean = false,
)

// ============================================================================
// 5. 异步工具 start/stop 与 Router 批处理模型
// ============================================================================

@Serializable
data class AsyncToolStartResult(
    val status: String = "Started",
    val handleId: String,
    val toolName: String,
    val startedAtMs: Long,
)

@Serializable
data class AsyncToolStopResult(
    val handleId: String,
    val stopped: Boolean,
    val status: String,
)

@Serializable
data class RouterTriggerEvent(
    val eventId: String,
    val kind: String, // "user_message" | "async_tool_completed" | "batch_rollup" | "health_escalation"
    val conversationId: String,
    val channelId: String,
    val chatId: String,
    val threadId: String? = null,
    val senderId: String,
    val summaryText: String,
    val createdAtMs: Long,
    val sourceMessageId: String? = null,
)

// ============================================================================
// 6. 健康巡检与外部 Watchdog 模型
// ============================================================================

@Serializable
enum class HealthActionKind {
    NUDGE,
    INTERRUPT_AND_REDELIVER,
    ESCALATE_NEEDS_YOU,
    APPROVAL_STUCK_ALERT,
    NODE_DISCONNECTED_ALERT,
    EXPIRE_OFFLINE_MAC_QUEUE,
    DISPATCH_ONLINE_MAC_QUEUE,
    EXEMPT_LONG_TOOL,
}

@Serializable
data class HealthTickAction(
    val workItemId: String,
    val action: HealthActionKind,
    val finding: String,
    val detail: String,
)

@Serializable
data class WatchdogAssessment(
    val workItemId: String,
    val makingProgress: Boolean,
    val onTrack: Boolean,
    val recommendation: String, // "continue" | "nudge" | "steer" | "stop"
    val rationale: String,
)

fun interface CloudWatchdogJudge {
    suspend fun assess(
        item: CloudWorkItemRecord,
        recentEvents: List<String>,
    ): WatchdogAssessment
}

// ============================================================================
// 7. 自动化三种模式 (DEDICATED / STANDALONE / HEARTBEAT) 与运行信封
// ============================================================================

@Serializable
enum class CloudAutomationMode {
    /** 每次运行新建独立临时会话，仅通过 32KiB AutomationMemory 传递状态 */
    STANDALONE,

    /** 首次运行创建该自动化专属长会话，后续持续追加，平时静默更新记忆，完成或 L3 异动时才发卡片（持续跟踪类默认） */
    DEDICATED,

    /** 当主会话空闲且不在 60s 冷却期内时直接追加到主会话；繁忙或冷却期自动延后 15s 重试 */
    HEARTBEAT,
}

@Serializable
data class CompletionPolicy(
    val stopWhenClause: String,
    val confidenceThreshold: Double = 0.80,
    val policyVersion: Int = 1,
)

@Serializable
data class CompletionEvaluationResult(
    val matched: Boolean,
    val confidence: Double,
    val reason: String,
)

fun interface CompletionPolicyEvaluator {
    suspend fun evaluate(
        policy: CompletionPolicy,
        runOutput: String,
        memoryText: String,
    ): CompletionEvaluationResult
}

@Serializable
data class CloudAutomationSpec(
    val automationId: String,
    val title: String,
    val prompt: String,
    val mode: CloudAutomationMode = CloudAutomationMode.DEDICATED,
    val maxIterations: Int? = null,
    val stopAfterConsecutiveFailures: Int = 3,
    val completionPolicy: CompletionPolicy? = null,
    val targetSessionId: String? = null,
)

@Serializable
data class CloudAutomationRecord(
    val automationId: String,
    val title: String,
    val prompt: String,
    val mode: CloudAutomationMode = CloudAutomationMode.DEDICATED,
    val enabled: Boolean = true,
    val disabledReason: String? = null, // "completed" | "max-iterations" | "failures" | "cancelled"
    val dedicatedSessionId: String? = null,
    val targetSessionId: String? = null,
    val iterationCount: Int = 0,
    val maxIterations: Int? = null,
    val consecutiveFailures: Int = 0,
    val stopAfterConsecutiveFailures: Int = 3,
    /** 数据库持久化上限 32 KiB (32,768 UTF-8 bytes) */
    val memoryText: String = "",
    val completionPolicy: CompletionPolicy? = null,
    val activeRunId: String? = null,
    val lastRunAtMs: Long? = null,
    val nextRetryAtMs: Long? = null,
    val createdAtMs: Long,
    val updatedAtMs: Long,
)

@Serializable
data class AutomationRunEnvelope(
    val automationId: String,
    val runId: String,
    val mode: CloudAutomationMode,
    val iteration: Int,
    val maxIterations: Int?,
    /** 数据库存储上限 32 KiB，注入 Prompt 时按 UTF-8 / Unicode 安全边界取尾部 8 KiB */
    val memoryTail8KiB: String,
    val completionPolicy: CompletionPolicy?,
) {
    fun renderPromptPrefix(): String = buildString {
        append("<amber_automation_run id=\"").append(automationId)
        append("\" run_id=\"").append(runId)
        append("\" mode=\"").append(mode.name.lowercase())
        append("\" iteration=\"").append(iteration)
        if (maxIterations != null) append("/").append(maxIterations)
        append("\">\n")
        if (completionPolicy != null) {
            append("StopWhen: ").append(completionPolicy.stopWhenClause)
                .append(" (threshold=").append(completionPolicy.confidenceThreshold).append(")\n")
        }
        append("MemoryTail8KiB:\n")
        append(memoryTail8KiB)
        append("\n</amber_automation_run>")
    }
}

@Serializable
data class AutomationTurnOutput(
    val summary: String,
    val updatedMemory: String? = null,
    val decision: String = "silent", // "silent" | "notify"
    val l3AnomalyDetected: Boolean = false,
    val selfCancel: Boolean = false,
    val failed: Boolean = false,
)

@Serializable
data class AutomationRunResult(
    val automationId: String,
    val runId: String,
    val sessionId: String,
    val mode: CloudAutomationMode,
    val iteration: Int,
    val decision: String,
    val cardPushed: Boolean,
    val disabled: Boolean,
    val disabledReason: String?,
    val deferredHeartbeat: Boolean = false,
    val nextRetryAtMs: Long? = null,
)

// ============================================================================
// 8. 异常类型与工具函数 (SHA-256、Unicode 安全切片、UTF-8 8KiB/32KiB 边界)
// ============================================================================

class PrincipalPermissionException(message: String) : IllegalStateException(message)
class UnauthorizedWorkSourceException(message: String) : IllegalArgumentException(message)
class WorkItemConflictException(message: String) : IllegalStateException(message)
class OptimisticLockConflictException(message: String) : IllegalStateException(message)
class MessageVersionMismatchException(message: String) : IllegalStateException(message)

object OrchestrationHash {
    const val AUTOMATION_MEMORY_MAX_BYTES = 32 * 1024
    const val AUTOMATION_MEMORY_INJECT_TAIL_BYTES = 8 * 1024

    fun sha256Hex(text: String): String {
        val digest = AmberNativeBridge.sha256(text.toByteArray(StandardCharsets.UTF_8))
            ?: error("SHA-256 unavailable on JVM")
        return digest.joinToString("") { "%02x".format(it) }
    }

    /**
     * 计算 Unicode 安全切片结束偏移，绝不拆开 UTF-16 高低代理对 (Surrogate Pair)。
     */
    fun unicodeSafeEndOffset(text: String, startOffset: Int, maxChars: Int): Int {
        if (startOffset >= text.length) return text.length
        val rawEnd = (startOffset + maxChars.coerceAtLeast(1)).coerceAtMost(text.length)
        if (rawEnd < text.length && rawEnd > startOffset) {
            if (Character.isHighSurrogate(text[rawEnd - 1]) && Character.isLowSurrogate(text[rawEnd])) {
                return if (rawEnd - 1 > startOffset) rawEnd - 1 else (rawEnd + 1).coerceAtMost(text.length)
            }
        }
        return rawEnd
    }

    /**
     * 确保起始偏移不会落在低代理项 (Low Surrogate) 上。
     */
    fun unicodeSafeStartOffset(text: String, requestedOffset: Int): Int {
        val clamped = requestedOffset.coerceIn(0, text.length)
        if (clamped in 1 until text.length && Character.isLowSurrogate(text[clamped]) && Character.isHighSurrogate(text[clamped - 1])) {
            return clamped - 1
        }
        return clamped
    }

    /**
     * 校验或截断 AutomationMemory 至 32 KiB UTF-8 字节上限（不截断代理对）。
     */
    fun enforceMaxUtf8Bytes(text: String, maxBytes: Int = AUTOMATION_MEMORY_MAX_BYTES): String {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var endChar = text.length
        while (endChar > 0) {
            val candidate = text.substring(0, endChar)
            if (candidate.toByteArray(StandardCharsets.UTF_8).size <= maxBytes) {
                if (endChar > 0 && Character.isHighSurrogate(text[endChar - 1])) {
                    endChar--
                }
                return text.substring(0, endChar)
            }
            endChar -= maxOf(1, (candidate.toByteArray(StandardCharsets.UTF_8).size - maxBytes) / 4)
        }
        return ""
    }

    /**
     * 按 UTF-8 / Unicode 安全边界取尾部 8 KiB。
     */
    fun utf8SafeTail(text: String, maxBytes: Int = AUTOMATION_MEMORY_INJECT_TAIL_BYTES): String {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var startChar = (text.length - maxBytes).coerceAtLeast(0)
        while (startChar < text.length) {
            startChar = unicodeSafeStartOffset(text, startChar)
            if (Character.isLowSurrogate(text[startChar])) {
                startChar++
                continue
            }
            val slice = text.substring(startChar)
            if (slice.toByteArray(StandardCharsets.UTF_8).size <= maxBytes) {
                return slice
            }
            startChar += maxOf(1, (slice.toByteArray(StandardCharsets.UTF_8).size - maxBytes) / 4)
        }
        return ""
    }

    /**
     * 统计中英文混合文本的词数：
     * - 英文/数字按连续空白分隔词统计；
     * - CJK 汉字按每个字计 1 词（或当全为空白分词时按 token 计），确保中英文都能严格受限于 100 词。
     */
    fun countWords(text: String): Int {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return 0
        val tokens = trimmed.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return tokens.size
    }
}

// ============================================================================
// 9. 云端编排内核主接口 (CloudOrchestrationKernel)
// ============================================================================

interface CloudOrchestrationKernel {

    val config: OrchestrationConfig

    /**
     * 批量派发跨端/子智能体任务（仅允许 [CloudPrincipal.CloudCoordinator] 调用）。
     * - 内部强制执行三层幂等（`scopeKey + taskKey -> workItemId`，以及 `requestId` 操作账本）。
     * - 校验 `contextMessageIds` 必须为已认证主人发出的真实人类消息（[SourceMessageProvenance]）。
     */
    suspend fun submitWorkBatch(
        principal: CloudPrincipal,
        requestId: String,
        contextMessageIds: List<String>,
        items: List<WorkItemSubmissionSpec>,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): BatchSubmissionResult

    /**
     * Worker 上报增量进度（乐观锁校验 `expectedRevision`，仅允许对应 `workItemId` 的 Worker 调用）。
     */
    suspend fun updateWorkerProgress(
        principal: CloudPrincipal,
        workItemId: String,
        expectedRevision: Int,
        progressNote: String,
        activeToolName: String? = null,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): CloudWorkItemRecord

    /**
     * Worker 提交终态结算报告：
     * - 落盘无时间戳的 `inbox/<workItemId>/report.md`（SQLite + SHA-256 + 原子文件）；
     * - 释放并发槽位并自动调度队列中下一个 `QUEUED` 任务；
     * - 若所属 `batchId` 全部进入终态，通过 `wakeClaim` 锁生成单条 `BatchRollup` 并唤醒 Router 一次。
     */
    suspend fun reportWorkerSettlement(
        principal: CloudPrincipal,
        report: WorkerSettlementReport,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): CloudWorkItemRecord

    /**
     * 向已有 Worker 追加重定向指令（采用两阶段槽位预留 admitFollowup + 失败自动回滚）。
     */
    suspend fun steerWorker(
        principal: CloudPrincipal,
        workItemId: String,
        followupInstruction: String,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): CloudWorkItemRecord

    /**
     * 双层游标读取子会话/远程节点执行记录（第一层：会话摘要页；第二层：Unicode 安全无损单消息切片）。
     */
    suspend fun readWorkerSessionPage(
        sessionId: String,
        pageCursor: String? = null,
        pageSize: Int = 20,
        maxMessageChars: Int = 1_500,
    ): SessionReadPage

    suspend fun readWorkerMessageSlice(
        cursor: MessageSliceCursor,
    ): MessageSliceResult

    /**
     * 一站式取证诊断（合并连续流式事件、经过 CredentialRedactor 脱敏并输出 findings 与 coverage）。
     */
    suspend fun diagnoseWorkerSession(
        sessionId: String,
        nowEpochMs: Long = System.currentTimeMillis(),
    ): SessionDiagnosticSnapshot

    /**
     * 链式召回（Chain of Recall）：按对象类型与 ID 召回摘要及下一跳关联对象列表。
     */
    suspend fun recallObject(
        kind: RecallObjectKind,
        id: String,
        inlineMaxChars: Int = 400,
    ): RecallNodeSnapshot?

    /**
     * 每 60 秒由后台协程调用的零 Token 确定性健康巡检：
     * - 启动超时 (3m)、审批超时 (5m)、运行静默 (10m)、长耗时工具豁免 (45m)、断连宽限 (90s)、离线 Mac 队列 24h 超期；
     * - 最多执行 2 次自愈阶梯（Step 1 Nudge -> Step 2 Interrupt & Redeliver），超限推送求助卡片。
     */
    suspend fun runDeterministicHealthTick(
        nowEpochMs: Long = System.currentTimeMillis(),
    ): List<HealthTickAction>

    /**
     * 定时消息驱动的外部 Watchdog（默认关闭模型判定，开启时调用 [CloudWatchdogJudge] 检查实质进展）。
     */
    suspend fun runWatchdogTick(
        nowEpochMs: Long = System.currentTimeMillis(),
    ): List<WatchdogAssessment>
}
