package app.amber.cloud.proactive

import app.amber.cloud.channels.FeishuCalendarEvent
import kotlinx.serialization.Serializable

/**
 * 主动推送紧迫度分级（冻结契约 §4.1）。
 */
@Serializable
enum class ProactiveUrgency {
    URGENT,
    NORMAL,
    DIGEST,
}

/**
 * 强主动性引擎的五类触发源分类（对齐 `amber-cloud-self-plan.md` §6.1）。
 */
@Serializable
enum class TriggerCategory {
    /** 1. 时间与周期（晨间简报 08:30、晚间复盘 21:00、周期巡检、一次性延时提醒） */
    CLOCK_CRON,

    /** 2. 外部信息源异动（Watchtower 网页监控、飞书/Apple 日历变更、Webhook） */
    EXTERNAL_SENSOR,

    /** 3. 边缘设备事件上报（Mac 本地文件夹新增文件、Claude Code / Codex 长任务状态变迁） */
    EDGE_NODE_EVENT,

    /** 4. 记忆与承诺跟进（对话提取的时间锚点到期、跨渠道事实冲突） */
    MEMORY_COMMITMENT,

    /** 5. 挂起任务生命周期（待审批超时提醒、离线节点重新上线恢复） */
    TASK_LIFECYCLE,
}

/**
 * 五类触发源产出的统一信号密封接口。
 */
sealed interface ProactiveTriggerSignal {
    val signalId: String
    val category: TriggerCategory
    val topicKey: String
    val timestampEpochMs: Long

    /** 类别 1：时钟与周期信号（如晨间简报、晚间复盘） */
    data class ClockCronSignal(
        override val signalId: String,
        val scheduleName: String,
        val dateString: String,
        val calendarEvents: List<FeishuCalendarEvent> = emptyList(),
        override val topicKey: String = "cron:$scheduleName:$dateString",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.CLOCK_CRON
    }

    /** 类别 2A：外部传感器 - Watchtower 网页抓取信号 */
    data class WatchtowerPageSignal(
        override val signalId: String,
        val url: String,
        val title: String = "",
        val httpStatusCode: Int = 200,
        val etag: String? = null,
        val rawBody: String = "",
        val conditionPrompt: String = "",
        val monitorId: String? = null,
        override val topicKey: String = "watchtower:$url",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
        val digest: Boolean = false,
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR
    }

    /** 类别 2B：外部传感器 - 日历快照同步信号 */
    data class CalendarSnapshotSignal(
        override val signalId: String,
        val datePrefix: String,
        val events: List<FeishuCalendarEvent>,
        override val topicKey: String = "calendar:$datePrefix",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR
    }

    /** 类别 2C：外部传感器 - 临近日程主动准备信号（会前 15–30 分钟） */
    data class UpcomingEventPrepSignal(
        override val signalId: String,
        val eventSignature: String,
        val eventTitle: String,
        val startMs: Long,
        val endMs: Long,
        val minutesUntilStart: Int,
        val deviceName: String = "",
        val recalledMemories: List<String> = emptyList(),
        override val topicKey: String = "prep:event:$eventSignature",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR
    }

    /** 类别 2D：外部传感器 - 个人签名入站 Webhook 信号 */
    data class WebhookInboundSignal(
        override val signalId: String,
        val webhookId: String,
        val webhookName: String,
        val deliveryId: String,
        val instruction: String = "",
        val redactedPayload: String,
        override val topicKey: String = "webhook:$webhookId",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
        val signedPayloadHash: String? = null,
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.EXTERNAL_SENSOR
    }

    /** 类别 3：边缘设备节点事件信号（文件夹新增文件 / 本地 Claude Code 或 Codex 状态变迁） */
    data class EdgeNodeSensorSignal(
        override val signalId: String,
        val nodeId: String,
        val eventKind: String, // "folder_new_files" | "agent_session_needs_you" | "agent_session_ended"
        val deduplicationKey: String,
        val summaryText: String,
        override val topicKey: String = "edge:$nodeId:$eventKind",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.EDGE_NODE_EVENT
    }

    /** 类别 4：记忆与承诺到期跟进信号 */
    data class MemoryCommitmentSignal(
        override val signalId: String,
        val memoryId: String,
        val commitmentText: String,
        val dueDateTime: String,
        override val topicKey: String = "commitment:$memoryId",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.MEMORY_COMMITMENT
    }

    /** 类别 4B：延期超过 24 小时的待办温和跟进信号（按日去重） */
    data class OverdueReminderPrepSignal(
        override val signalId: String,
        val dateKey: String,
        val overdueItems: List<String>,
        val deviceName: String = "",
        override val topicKey: String = "prep:overdue_reminders:$dateKey",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.MEMORY_COMMITMENT
    }

    /** 类别 5：挂起任务生命周期信号（待审批超时预警 / 离线节点上线恢复） */
    data class TaskLifecycleSignal(
        override val signalId: String,
        val taskId: String,
        val lifecycleState: String, // "approval_expiring" | "node_online_resumed"
        val detail: String,
        val approvalToolCallId: String? = null,
        override val topicKey: String = "task:$taskId:$lifecycleState",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory = TriggerCategory.TASK_LIFECYCLE
    }

    /** 类别 1B / 4C：自唤醒信号（snooze 延后提醒 / Agent 自定回访 / 隐式承诺到期） */
    data class SelfWakeupSignal(
        override val signalId: String,    // 遵循 "wk_{wakeupId}_{epochMin}"，匹配 ^[A-Za-z0-9_-]{1,48}$
        val wakeupId: String,
        val kind: String,                 // "snooze" | "agent" | "commitment"
        val title: String,                // ≤100，已脱敏
        val detail: String = "",          // ≤1000
        val checkPrompt: String? = null,  // ≤2000
        val userRequested: Boolean = false,
        val originSignalId: String? = null,
        override val topicKey: String = "wakeup:$wakeupId",
        override val timestampEpochMs: Long = System.currentTimeMillis(),
    ) : ProactiveTriggerSignal {
        override val category: TriggerCategory =
            if (kind == "commitment") TriggerCategory.MEMORY_COMMITMENT else TriggerCategory.CLOCK_CRON
    }
}

/**
 * 主动触发源统一接口（支持五类触发源按需注册与轮询）。
 */
interface TriggerSource {
    val id: String
    val category: TriggerCategory

    /**
     * 采集下一次触发信号；若当前无信号则返回 `null`。
     */
    suspend fun poll(): ProactiveTriggerSignal? = null

    /**
     * 采集本轮所有到期触发信号；默认委托给单信号 [poll]。
     */
    suspend fun pollAll(nowEpochMs: Long = System.currentTimeMillis()): List<ProactiveTriggerSignal> =
        listOfNotNull(poll())

    /** A cancellable source can claim the item immediately before processing its poll snapshot. */
    suspend fun processIfCurrent(
        signal: ProactiveTriggerSignal,
        process: suspend () -> ProactiveRunResult,
    ): ProactiveRunResult? = process()

    /**
     * 单个信号在流水线处理完成后的回调（供触发源更新退避周期、状态摘要等）。
     */
    suspend fun onResult(
        signal: ProactiveTriggerSignal,
        result: ProactiveRunResult,
        nowEpochMs: Long = System.currentTimeMillis(),
    ) = Unit
}
