package app.amber.cloud.orchestration

import app.amber.ai.ui.UIMessage
import app.amber.cloud.channel.OutboundCard
import app.amber.cloud.channel.PRIMARY_CONVERSATION_ID
import app.amber.cloud.proactive.ProactiveRunResult
import app.amber.cloud.proactive.ProactiveTriggerSignal
import app.amber.cloud.security.CredentialRedactor
import java.util.UUID
import kotlin.uuid.Uuid

/**
 * 负责自动化三种运行模式（`DEDICATED` 默认静默仅在完成或 L3 异动时发 1 张卡、`STANDALONE`、`HEARTBEAT`）、
 * 四种停机策略（`cancelled`、`failures`、`completed`、`max-iterations`）、
 * 32 KiB 持久化记忆上限 + 8 KiB 尾部单轮信封注入，以及与 `ProactiveEngine` 的信号桥接。
 */
internal class OrchestrationAutomationRunner(
    private val kernel: DefaultCloudOrchestrationKernel,
) {
    @Volatile
    private var lastHeartbeatRunAtMs: Long = Long.MIN_VALUE

    fun registerAutomation(
        spec: CloudAutomationSpec,
        nowEpochMs: Long,
    ): CloudAutomationRecord {
        val existing = kernel.store.getAutomation(spec.automationId)
        val dedicatedSession = when (spec.mode) {
            CloudAutomationMode.DEDICATED -> existing?.dedicatedSessionId ?: Uuid.random().toString()
            else -> null
        }
        val record = CloudAutomationRecord(
            automationId = spec.automationId,
            title = CredentialRedactor.redact(spec.title),
            prompt = CredentialRedactor.redact(spec.prompt),
            mode = spec.mode,
            enabled = true,
            disabledReason = null,
            dedicatedSessionId = dedicatedSession,
            targetSessionId = spec.targetSessionId ?: PRIMARY_CONVERSATION_ID.toString(),
            iterationCount = existing?.iterationCount ?: 0,
            maxIterations = spec.maxIterations,
            consecutiveFailures = 0,
            stopAfterConsecutiveFailures = spec.stopAfterConsecutiveFailures.coerceAtLeast(1),
            memoryText = existing?.memoryText ?: "",
            completionPolicy = spec.completionPolicy,
            intervalMs = spec.intervalMs.coerceAtLeast(60_000L),
            createdAtMs = existing?.createdAtMs ?: nowEpochMs,
            updatedAtMs = nowEpochMs,
        )
        kernel.store.upsertAutomation(record)
        return record
    }

    suspend fun runDueAutomations(
        nowEpochMs: Long,
        turnExecutor: suspend (AutomationRunEnvelope, CloudPrincipal.AutomationRunner, String) -> AutomationTurnOutput,
    ): List<AutomationRunResult> {
        val due = kernel.store.listAutomations().filter { rec ->
            rec.enabled && rec.activeRunId == null && when {
                rec.nextRetryAtMs != null -> nowEpochMs >= rec.nextRetryAtMs
                rec.lastRunAtMs == null -> true
                else -> nowEpochMs - rec.lastRunAtMs >= rec.intervalMs
            }
        }
        return due.map { executeAutomationRun(it.automationId, nowEpochMs, turnExecutor) }
    }

    fun updateAutomationMemory(
        principal: CloudPrincipal,
        automationId: String,
        newMemory: String,
        nowEpochMs: Long,
    ): CloudAutomationRecord {
        if (principal !is CloudPrincipal.AutomationRunner || principal.automationId != automationId) {
            throw PrincipalPermissionException("仅当前自动化触发轮次 (AutomationRunner) 允许更新 AutomationMemory")
        }
        val existing = kernel.store.getAutomation(automationId)
            ?: throw IllegalArgumentException("找不到自动化任务: $automationId")
        if (existing.activeRunId == null || existing.activeRunId != principal.runId) {
            throw PrincipalPermissionException("自动化授权信封已失效或不属于当前轮次 (runId=${principal.runId})，禁止在手动跟进轮次中修改自动化记忆")
        }
        val safeMemory = OrchestrationHash.enforceMaxUtf8Bytes(
            CredentialRedactor.redact(newMemory),
            OrchestrationHash.AUTOMATION_MEMORY_MAX_BYTES,
        )
        val updated = existing.copy(
            memoryText = safeMemory,
            updatedAtMs = nowEpochMs,
        )
        kernel.store.upsertAutomation(updated)
        return updated
    }

    fun cancelAutomation(
        principal: CloudPrincipal,
        automationId: String,
        nowEpochMs: Long,
    ): CloudAutomationRecord {
        if (principal is CloudPrincipal.Worker || principal is CloudPrincipal.ExternalCaller) {
            throw PrincipalPermissionException("当前主体 (${principal.principalId}) 无权取消自动化: $automationId")
        }
        val existing = kernel.store.getAutomation(automationId)
            ?: throw IllegalArgumentException("找不到自动化任务: $automationId")
        val cancelled = existing.copy(
            enabled = false,
            disabledReason = "cancelled",
            activeRunId = null,
            updatedAtMs = nowEpochMs,
        )
        kernel.store.upsertAutomation(cancelled)
        return cancelled
    }

    suspend fun executeAutomationRun(
        automationId: String,
        nowEpochMs: Long,
        turnExecutor: suspend (AutomationRunEnvelope, CloudPrincipal.AutomationRunner, String) -> AutomationTurnOutput,
    ): AutomationRunResult {
        val record = kernel.store.getAutomation(automationId)
            ?: throw IllegalArgumentException("找不到自动化任务: $automationId")
        if (!record.enabled) {
            return AutomationRunResult(
                automationId = automationId,
                runId = "disabled",
                sessionId = record.dedicatedSessionId ?: PRIMARY_CONVERSATION_ID.toString(),
                mode = record.mode,
                iteration = record.iterationCount,
                decision = "silent",
                cardPushed = false,
                disabled = true,
                disabledReason = record.disabledReason,
            )
        }

        if (record.mode == CloudAutomationMode.HEARTBEAT) {
            val inCooldown = lastHeartbeatRunAtMs != Long.MIN_VALUE && (nowEpochMs - lastHeartbeatRunAtMs) < 60_000L
            if (kernel.isRouterTurnBusy || inCooldown) {
                val retryAt = nowEpochMs + 15_000L
                kernel.store.upsertAutomation(record.copy(nextRetryAtMs = retryAt, updatedAtMs = nowEpochMs))
                return AutomationRunResult(
                    automationId = automationId,
                    runId = "deferred",
                    sessionId = record.targetSessionId ?: PRIMARY_CONVERSATION_ID.toString(),
                    mode = record.mode,
                    iteration = record.iterationCount,
                    decision = "silent",
                    cardPushed = false,
                    disabled = false,
                    disabledReason = null,
                    deferredHeartbeat = true,
                    nextRetryAtMs = retryAt,
                )
            }
            lastHeartbeatRunAtMs = nowEpochMs
        }

        val sessionId = when (record.mode) {
            CloudAutomationMode.STANDALONE -> Uuid.random().toString()
            CloudAutomationMode.DEDICATED -> record.dedicatedSessionId ?: Uuid.random().toString()
            CloudAutomationMode.HEARTBEAT -> record.targetSessionId ?: PRIMARY_CONVERSATION_ID.toString()
        }

        val nextIteration = record.iterationCount + 1
        val runId = "autorun:" + UUID.randomUUID().toString().lowercase().take(16)
        val tail8KiB = OrchestrationHash.utf8SafeTail(
            record.memoryText,
            OrchestrationHash.AUTOMATION_MEMORY_INJECT_TAIL_BYTES,
        )
        val envelope = AutomationRunEnvelope(
            automationId = automationId,
            runId = runId,
            mode = record.mode,
            iteration = nextIteration,
            maxIterations = record.maxIterations,
            memoryTail8KiB = tail8KiB,
            completionPolicy = record.completionPolicy,
        )

        val runningRecord = record.copy(
            dedicatedSessionId = if (record.mode == CloudAutomationMode.DEDICATED) sessionId else record.dedicatedSessionId,
            activeRunId = runId,
            updatedAtMs = nowEpochMs,
        )
        kernel.store.upsertAutomation(runningRecord)

        val runnerPrincipal = CloudPrincipal.AutomationRunner(
            principalId = "automation:$automationId:$runId",
            automationId = automationId,
            runId = runId,
            iteration = nextIteration,
        )

        val injectedPrompt = "${envelope.renderPromptPrefix()}\n\n${record.prompt}"
        kernel.appendMessageToSessionInternal(sessionId, UIMessage.user(injectedPrompt), nowEpochMs)

        val output = try {
            turnExecutor(envelope, runnerPrincipal, sessionId)
        } catch (t: Throwable) {
            AutomationTurnOutput(
                summary = "执行异常: ${CredentialRedactor.redact(t.message.orEmpty())}",
                decision = "notify",
                failed = true,
            )
        }

        kernel.appendMessageToSessionInternal(
            sessionId = sessionId,
            message = UIMessage.assistant(CredentialRedactor.redact(output.summary)),
            nowEpochMs = nowEpochMs,
        )

        val afterTurn = kernel.store.getAutomation(automationId) ?: runningRecord
        val mergedMemory = if (output.updatedMemory != null) {
            OrchestrationHash.enforceMaxUtf8Bytes(
                CredentialRedactor.redact(output.updatedMemory),
                OrchestrationHash.AUTOMATION_MEMORY_MAX_BYTES,
            )
        } else {
            afterTurn.memoryText
        }

        var disabled = !afterTurn.enabled
        var disabledReason = afterTurn.disabledReason
        val consecutiveFailures = if (output.failed) afterTurn.consecutiveFailures + 1 else 0

        if (output.selfCancel || disabledReason == "cancelled") {
            disabled = true
            disabledReason = "cancelled"
        }

        if (!disabled && output.failed && consecutiveFailures >= afterTurn.stopAfterConsecutiveFailures) {
            disabled = true
            disabledReason = "failures"
        }

        if (!disabled && !output.failed && afterTurn.completionPolicy != null) {
            val eval = kernel.completionPolicyEvaluator.evaluate(
                policy = afterTurn.completionPolicy,
                runOutput = output.summary,
                memoryText = mergedMemory,
            )
            if (eval.matched && eval.confidence >= afterTurn.completionPolicy.confidenceThreshold) {
                disabled = true
                disabledReason = "completed"
            }
        }

        if (!disabled && afterTurn.maxIterations != null && nextIteration >= afterTurn.maxIterations) {
            disabled = true
            disabledReason = "max-iterations"
        }

        val finalRecord = afterTurn.copy(
            enabled = !disabled,
            disabledReason = disabledReason,
            iterationCount = nextIteration,
            consecutiveFailures = consecutiveFailures,
            memoryText = mergedMemory,
            activeRunId = null,
            lastRunAtMs = nowEpochMs,
            nextRetryAtMs = null,
            updatedAtMs = nowEpochMs,
        )
        kernel.store.upsertAutomation(finalRecord)

        val shouldPushCard = when (record.mode) {
            CloudAutomationMode.DEDICATED -> {
                output.l3AnomalyDetected ||
                    disabledReason == "completed" ||
                    disabledReason == "max-iterations" ||
                    disabledReason == "failures"
            }
            CloudAutomationMode.STANDALONE,
            CloudAutomationMode.HEARTBEAT,
            -> output.decision.equals("notify", ignoreCase = true) || output.l3AnomalyDetected || disabled
        }

        var actuallyPushed = false
        if (shouldPushCard) {
            val cardTitle = when {
                output.l3AnomalyDetected -> "自动化 L3 异动预警 · ${record.title}"
                disabledReason == "completed" || disabledReason == "max-iterations" -> "持续跟踪完成 · ${record.title}"
                disabledReason == "failures" -> "自动化连续失败熔断 · ${record.title}"
                else -> "自动化通知 · ${record.title}"
            }
            val safeBody = CredentialRedactor.redact(output.summary)
            val fallbackCard = OutboundCard(
                title = cardTitle,
                markdownBody = safeBody,
                headerTemplate = if (output.failed || output.l3AnomalyDetected) "amber" else "wathet",
                highRisk = false,
            )
            val engine = kernel.proactiveEngine
            val cardToDeliver = if (engine != null) {
                val lifecycleState = disabledReason ?: "l3_anomaly"
                val signal = ProactiveTriggerSignal.TaskLifecycleSignal(
                    signalId = "auto_${automationId}_$runId",
                    taskId = automationId,
                    lifecycleState = lifecycleState,
                    detail = "$cardTitle: $safeBody",
                    topicKey = "automation:$automationId:$lifecycleState",
                    timestampEpochMs = nowEpochMs,
                )
                when (val proactiveRes = engine.processSignal(signal, targetChatId = "", channel = null, nowOverrideMs = nowEpochMs)) {
                    is ProactiveRunResult.PushedAtL3 -> proactiveRes.card
                    else -> null
                }
            } else {
                fallbackCard
            }
            if (cardToDeliver != null) {
                actuallyPushed = true
                kernel.onOwnerNotificationCard?.invoke(cardToDeliver, automationId)
            }
        }

        return AutomationRunResult(
            automationId = automationId,
            runId = runId,
            sessionId = sessionId,
            mode = record.mode,
            iteration = nextIteration,
            decision = if (shouldPushCard) "notify" else "silent",
            cardPushed = actuallyPushed,
            disabled = disabled,
            disabledReason = disabledReason,
        )
    }
}
