package app.amber.ai.core

import app.amber.ai.ui.MessageChunk
import app.amber.ai.ui.MessageStreamAccumulator
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessageChoice
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TokenUsageTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun defaultsAndLegacyJsonKeepCacheCreationTokensZero() {
        val empty = TokenUsage()
        assertEquals(0, empty.cacheCreationTokens)
        assertEquals(0, empty.uncachedInputTokens)

        // 5-argument compatibility constructor (used by Swift callers)
        val swiftCompat = TokenUsage(100, 20, 40, 120, 500)
        assertEquals(0, swiftCompat.cacheCreationTokens)
        assertEquals(60, swiftCompat.uncachedInputTokens)

        // Legacy serialized payload without cacheCreationTokens
        val legacyJson = """{"promptTokens":150,"completionTokens":30,"cachedTokens":50,"totalTokens":180,"generationDurationMs":400}"""
        val decoded = json.decodeFromString<TokenUsage>(legacyJson)
        assertEquals(150, decoded.promptTokens)
        assertEquals(50, decoded.cachedTokens)
        assertEquals(0, decoded.cacheCreationTokens)
        assertEquals(100, decoded.uncachedInputTokens)

        // Round-trip preserves cacheCreationTokens
        val withWrite = TokenUsage(
            promptTokens = 1_200,
            completionTokens = 80,
            cachedTokens = 200,
            totalTokens = 1_280,
            generationDurationMs = 900,
            cacheCreationTokens = 900,
        )
        assertEquals(withWrite, json.decodeFromString<TokenUsage>(json.encodeToString(withWrite)))
        assertEquals(100, withWrite.uncachedInputTokens)
    }

    @Test
    fun uncachedInputTokensClampsAtZeroOnInconsistentTotals() {
        val anomalous = TokenUsage(
            promptTokens = 100,
            cachedTokens = 80,
            cacheCreationTokens = 50,
        )
        assertEquals(0, anomalous.uncachedInputTokens)
    }

    @Test
    fun mergePreservesCacheCreationTokensAcrossStreamChunksWithoutDoubleCounting() {
        val messageStart = TokenUsage(
            promptTokens = 1_500,
            completionTokens = 1,
            cachedTokens = 400,
            totalTokens = 1_501,
            cacheCreationTokens = 1_000,
        )
        val messageDelta = TokenUsage(
            promptTokens = 0,
            completionTokens = 64,
            cachedTokens = 0,
            totalTokens = 64,
            cacheCreationTokens = 0,
        )

        val merged = messageStart.merge(messageDelta)
        assertEquals(1_500, merged.promptTokens)
        assertEquals(64, merged.completionTokens)
        assertEquals(400, merged.cachedTokens)
        assertEquals(1_000, merged.cacheCreationTokens)
        assertEquals(100, merged.uncachedInputTokens)
        assertEquals(1_564, merged.totalTokens)

        // Authoritative follow-up usage overrides instead of double-counting
        val authoritativeDelta = TokenUsage(
            promptTokens = 1_500,
            completionTokens = 70,
            cachedTokens = 400,
            totalTokens = 1_570,
            cacheCreationTokens = 1_000,
        )
        val mergedAgain = merged.merge(authoritativeDelta)
        assertEquals(1_000, mergedAgain.cacheCreationTokens)
        assertEquals(70, mergedAgain.completionTokens)
    }

    @Test
    fun plusAndSumUsageAccumulateAcrossTurnsWithoutDroppingCacheCreationTokens() {
        val turn1 = TokenUsage(
            promptTokens = 1_000,
            completionTokens = 50,
            cachedTokens = 0,
            totalTokens = 1_050,
            generationDurationMs = 400,
            cacheCreationTokens = 1_000,
        )
        val turn2 = TokenUsage(
            promptTokens = 1_000,
            completionTokens = 80,
            cachedTokens = 1_000,
            totalTokens = 1_080,
            generationDurationMs = 600,
            cacheCreationTokens = 0,
        )
        val turn3 = TokenUsage(
            promptTokens = 1_200,
            completionTokens = 40,
            cachedTokens = 900,
            totalTokens = 1_240,
            generationDurationMs = 300,
            cacheCreationTokens = 200,
        )

        val total = listOf(turn1, turn2, turn3).sumUsage()
        assertEquals(turn1 + turn2 + turn3, total)
        assertEquals(3_200, total.promptTokens)
        assertEquals(170, total.completionTokens)
        assertEquals(1_900, total.cachedTokens)
        assertEquals(1_200, total.cacheCreationTokens)
        assertEquals(100, total.uncachedInputTokens)
        assertEquals(3_370, total.totalTokens)
        assertEquals(1_300, total.generationDurationMs)
    }

    @Test
    fun promptCacheNetCostMatchesOneWriteZeroReadAndOneWriteOneRead() {
        // 1 write, 0 reads (5m default: 1.25x write, 0.1x read) => +25% vs 1.0x uncached
        val writeOnly = TokenUsage(
            promptTokens = 1_000,
            completionTokens = 20,
            cachedTokens = 0,
            totalTokens = 1_020,
            cacheCreationTokens = 1_000,
        )
        val writeOnlyCost = writeOnly.estimatePromptCacheInputCost()
        assertEquals(0, writeOnlyCost.uncachedInputTokens)
        assertEquals(0, writeOnlyCost.cacheReadTokens)
        assertEquals(1_000, writeOnlyCost.cacheCreationTokens)
        assertApprox(1_250.0, writeOnlyCost.effectiveInputTokens)
        assertApprox(1_000.0, writeOnlyCost.uncachedBaselineInputTokens)
        assertApprox(250.0, writeOnlyCost.netInputTokenDelta)
        assertApprox(0.25, writeOnlyCost.netDeltaRatio)
        assertApprox(1.25, writeOnlyCost.effectiveMultiplier)

        // 1 write, 1 read (5m default) => 1.35x vs 2.0x uncached => -32.5%
        val readOnly = TokenUsage(
            promptTokens = 1_000,
            completionTokens = 20,
            cachedTokens = 1_000,
            totalTokens = 1_020,
            cacheCreationTokens = 0,
        )
        val twoTurns = writeOnly + readOnly
        val twoTurnCost = twoTurns.estimatePromptCacheInputCost()
        assertEquals(0, twoTurnCost.uncachedInputTokens)
        assertEquals(1_000, twoTurnCost.cacheReadTokens)
        assertEquals(1_000, twoTurnCost.cacheCreationTokens)
        assertApprox(1_350.0, twoTurnCost.effectiveInputTokens)
        assertApprox(2_000.0, twoTurnCost.uncachedBaselineInputTokens)
        assertApprox(-650.0, twoTurnCost.netInputTokenDelta)
        assertApprox(-0.325, twoTurnCost.netDeltaRatio)
        assertApprox(0.675, twoTurnCost.effectiveMultiplier)

        // 1h write tier (2.0x write, 0.1x read): 1 write + 1 read => 2.1x vs 2.0x (+5%)
        val oneHourCost = twoTurns.estimatePromptCacheInputCost(PromptCacheWriteTier.EPHEMERAL_1H)
        assertApprox(2_100.0, oneHourCost.effectiveInputTokens)
        assertApprox(0.05, oneHourCost.netDeltaRatio)

        // Zero-input usage safely reports 0% delta and 1.0x multiplier
        val zeroCost = TokenUsage().estimatePromptCacheInputCost()
        assertApprox(0.0, zeroCost.netDeltaRatio)
        assertApprox(1.0, zeroCost.effectiveMultiplier)
    }

    @Test
    fun accumulatorAttachesInitialChunkUsageToAssistantAfterRoleTransition() {
        val accumulator = MessageStreamAccumulator(listOf(UIMessage.user("hello")))

        // Initial assistant chunk carrying prompt + cacheCreation usage (Claude message_start shape)
        accumulator.append(
            MessageChunk(
                id = "msg_1",
                model = "claude-sonnet-4-5",
                choices = listOf(
                    UIMessageChoice(
                        index = 0,
                        delta = UIMessage(role = MessageRole.ASSISTANT, parts = emptyList()),
                        message = null,
                        finishReason = null,
                    ),
                ),
                usage = TokenUsage(
                    promptTokens = 1_250,
                    completionTokens = 1,
                    cachedTokens = 200,
                    totalTokens = 1_251,
                    cacheCreationTokens = 1_000,
                ),
            ),
        )
        // Follow-up text delta
        accumulator.append(
            MessageChunk(
                id = "msg_1",
                model = "claude-sonnet-4-5",
                choices = listOf(
                    UIMessageChoice(
                        index = 0,
                        delta = UIMessage.assistant("world"),
                        message = null,
                        finishReason = null,
                    ),
                ),
                usage = null,
            ),
        )
        // Final usage-only chunk (OpenAI empty-choices shape)
        accumulator.append(
            MessageChunk(
                id = "msg_1",
                model = "claude-sonnet-4-5",
                choices = emptyList(),
                usage = TokenUsage(
                    promptTokens = 0,
                    completionTokens = 45,
                    cachedTokens = 0,
                    totalTokens = 45,
                    cacheCreationTokens = 0,
                ),
            ),
        )

        val snapshot = accumulator.snapshot()
        assertEquals(2, snapshot.size)
        assertNull(snapshot[0].usage)
        val assistantUsage = snapshot[1].usage
        assertEquals(1_250, assistantUsage?.promptTokens)
        assertEquals(45, assistantUsage?.completionTokens)
        assertEquals(200, assistantUsage?.cachedTokens)
        assertEquals(1_000, assistantUsage?.cacheCreationTokens)
        assertEquals(50, assistantUsage?.uncachedInputTokens)
        assertEquals(1_295, assistantUsage?.totalTokens)
    }

    private fun assertApprox(expected: Double, actual: Double, epsilon: Double = 1e-9) {
        assertTrue(
            abs(expected - actual) <= epsilon,
            "Expected $expected (+/- $epsilon) but was $actual",
        )
    }
}
