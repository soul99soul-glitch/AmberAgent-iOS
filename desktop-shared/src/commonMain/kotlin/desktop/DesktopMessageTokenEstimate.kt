package desktop

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart

// Approximate request size, using iOS's weighted-character rule and unknown-image budget.
internal fun estimateDesktopMessageTokens(message: UIMessage): Int =
    ((message.role.name.length + message.parts.sumOf(::estimatedPartChars)) / 4).coerceAtLeast(4)

private fun estimatedPartChars(part: UIMessagePart): Int = when (part) {
    is UIMessagePart.Text -> weightedTokenChars(part.text)
    is UIMessagePart.Reasoning -> weightedTokenChars(part.reasoning)
    is UIMessagePart.Tool -> weightedTokenChars(part.input) + part.output.sumOf(::estimatedPartChars)
    is UIMessagePart.Image -> 1_600 * 4
    is UIMessagePart.Audio, is UIMessagePart.Video -> 4_500
    is UIMessagePart.Document -> part.fileName.length + 80
    is UIMessagePart.MiniApp -> weightedTokenChars(part.title) + weightedTokenChars(part.description) + 120
}

private fun weightedTokenChars(value: String): Int {
    var total = 0
    var index = 0
    while (index < value.length) {
        val first = value[index++]
        val scalar = if (first.isHighSurrogate() && index < value.length && value[index].isLowSurrogate()) {
            0x10000 + ((first.code - 0xD800) shl 10) + (value[index++].code - 0xDC00)
        } else first.code
        val cjk = scalar in 0x4E00..0x9FFF || scalar in 0x3400..0x4DBF || scalar in 0x20000..0x2A6DF ||
            scalar in 0x2A700..0x2B73F || scalar in 0x2B740..0x2B81F || scalar in 0x2B820..0x2CEAF ||
            scalar in 0xF900..0xFAFF || scalar in 0x2F800..0x2FA1F
        total += if (cjk) 4 else 1
    }
    return total
}
