package app.amber.ai.core

import kotlinx.serialization.Serializable

const val DEFAULT_PROMPT_CACHE_READ_MULTIPLIER: Double = 0.1

enum class PromptCacheWriteTier(val writeMultiplier: Double) {
    /** Anthropic 5-minute ephemeral cache write (1.25x base input rate). */
    EPHEMERAL_5M(1.25),

    /** Anthropic 1-hour ephemeral cache write (2.0x base input rate). */
    EPHEMERAL_1H(2.0),
}

/**
 * Token accounting for one or more LLM turns.
 *
 * Prompt input breakdown:
 * `promptTokens = uncachedInputTokens + cachedTokens (cache read) + cacheCreationTokens (cache write)`.
 */
@Serializable
data class TokenUsage(
    val promptTokens: Int = 0,
    val completionTokens: Int = 0,
    val cachedTokens: Int = 0,
    val totalTokens: Int = 0,
    /// Visible decode time for the last LLM round, excluding tool/approval waits.
    /// 0 means unknown (older messages, or no visible delta was observed).
    val generationDurationMs: Int = 0,
    /// Tokens written into the provider prompt cache during this turn
    /// (e.g. Anthropic `cache_creation_input_tokens`). Included in [promptTokens].
    val cacheCreationTokens: Int = 0,
) {
    /**
     * Swift/ObjC 5-argument compatibility initializer (Kotlin default arguments
     * do not generate Swift initializer overloads).
     */
    constructor(
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int,
        totalTokens: Int,
        generationDurationMs: Int,
    ) : this(
        promptTokens = promptTokens,
        completionTokens = completionTokens,
        cachedTokens = cachedTokens,
        totalTokens = totalTokens,
        generationDurationMs = generationDurationMs,
        cacheCreationTokens = 0,
    )

    /**
     * Uncached input tokens billed at 1.0x base input rate:
     * `maxOf(0, promptTokens - cachedTokens - cacheCreationTokens)`.
     */
    val uncachedInputTokens: Int
        get() = maxOf(0, promptTokens - cachedTokens - cacheCreationTokens)

    /**
     * Accumulates usage across multiple LLM turns (sum semantics, unlike [merge]
     * which combines partial chunks within a single streaming response).
     */
    operator fun plus(other: TokenUsage): TokenUsage {
        val prompt = promptTokens + other.promptTokens
        val completion = completionTokens + other.completionTokens
        return TokenUsage(
            promptTokens = prompt,
            completionTokens = completion,
            cachedTokens = cachedTokens + other.cachedTokens,
            totalTokens = prompt + completion,
            generationDurationMs = generationDurationMs + other.generationDurationMs,
            cacheCreationTokens = cacheCreationTokens + other.cacheCreationTokens,
        )
    }
}

fun TokenUsage?.merge(other: TokenUsage): TokenUsage {
    val promptTokens = if (other.promptTokens > 0) {
        other.promptTokens
    } else {
        this?.promptTokens ?: 0
    }
    val completionTokens = if (other.completionTokens > 0) {
        other.completionTokens
    } else {
        this?.completionTokens ?: 0
    }
    val totalTokens = promptTokens + completionTokens
    val cachedTokens = if (other.cachedTokens > 0) {
        other.cachedTokens
    } else {
        this?.cachedTokens ?: 0
    }
    val cacheCreationTokens = if (other.cacheCreationTokens > 0) {
        other.cacheCreationTokens
    } else {
        this?.cacheCreationTokens ?: 0
    }
    val generationDurationMs = if (other.generationDurationMs > 0) {
        other.generationDurationMs
    } else {
        this?.generationDurationMs ?: 0
    }
    return TokenUsage(
        promptTokens = promptTokens,
        completionTokens = completionTokens,
        totalTokens = totalTokens,
        cachedTokens = cachedTokens,
        generationDurationMs = generationDurationMs,
        cacheCreationTokens = cacheCreationTokens,
    )
}

fun Iterable<TokenUsage>.sumUsage(): TokenUsage =
    fold(TokenUsage()) { acc, usage -> acc + usage }

/**
 * Equivalent input-token cost breakdown for prompt caching net accounting.
 *
 * All token equivalents are expressed in units of 1.0x uncached base input tokens.
 */
data class PromptCacheInputCostEstimate(
    val uncachedInputTokens: Int,
    val cacheReadTokens: Int,
    val cacheCreationTokens: Int,
    val totalInputTokens: Int,
    val writeMultiplier: Double,
    val readMultiplier: Double,
    val effectiveInputTokens: Double,
    val uncachedBaselineInputTokens: Double,
) {
    /** Net equivalent input token delta vs uncached baseline (negative = savings, positive = overhead). */
    val netInputTokenDelta: Double
        get() = effectiveInputTokens - uncachedBaselineInputTokens

    /** Net cost ratio delta vs uncached baseline (e.g. +0.25 = +25%, -0.325 = -32.5%). */
    val netDeltaRatio: Double
        get() = if (uncachedBaselineInputTokens > 0.0) {
            netInputTokenDelta / uncachedBaselineInputTokens
        } else {
            0.0
        }

    /** Effective input billing multiplier relative to 1.0x uncached baseline. */
    val effectiveMultiplier: Double
        get() = if (uncachedBaselineInputTokens > 0.0) {
            effectiveInputTokens / uncachedBaselineInputTokens
        } else {
            1.0
        }
}

fun TokenUsage.estimatePromptCacheInputCost(
    writeMultiplier: Double = PromptCacheWriteTier.EPHEMERAL_5M.writeMultiplier,
    readMultiplier: Double = DEFAULT_PROMPT_CACHE_READ_MULTIPLIER,
): PromptCacheInputCostEstimate {
    require(writeMultiplier >= 0.0) { "writeMultiplier must be non-negative: $writeMultiplier" }
    require(readMultiplier >= 0.0) { "readMultiplier must be non-negative: $readMultiplier" }
    val uncached = uncachedInputTokens
    val read = maxOf(0, cachedTokens)
    val write = maxOf(0, cacheCreationTokens)
    val totalInput = uncached + read + write
    val baseline = totalInput.toDouble()
    val effective = uncached + read * readMultiplier + write * writeMultiplier
    return PromptCacheInputCostEstimate(
        uncachedInputTokens = uncached,
        cacheReadTokens = read,
        cacheCreationTokens = write,
        totalInputTokens = totalInput,
        writeMultiplier = writeMultiplier,
        readMultiplier = readMultiplier,
        effectiveInputTokens = effective,
        uncachedBaselineInputTokens = baseline,
    )
}

fun TokenUsage.estimatePromptCacheInputCost(
    writeTier: PromptCacheWriteTier,
    readMultiplier: Double = DEFAULT_PROMPT_CACHE_READ_MULTIPLIER,
): PromptCacheInputCostEstimate = estimatePromptCacheInputCost(
    writeMultiplier = writeTier.writeMultiplier,
    readMultiplier = readMultiplier,
)
