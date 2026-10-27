package desktop

import app.amber.ai.core.MessageRole
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import kotlin.test.Test
import kotlin.test.assertEquals

class DesktopTokenEstimateTest {
    @Test
    fun cjkAndSupplementaryScalarsUseTheIosWeightedCharacterRule() {
        assertEquals(4, estimateDesktopMessageTokens(UIMessage.user("abcdefgh")))
        assertEquals(9, estimateDesktopMessageTokens(UIMessage.user("中文甲乙丙丁戊己")))
        assertEquals(9, estimateDesktopMessageTokens(UIMessage.user("\uD840\uDC00".repeat(8))))
        assertEquals(4, estimateDesktopMessageTokens(UIMessage.user("😀".repeat(8))))
        assertEquals(4, estimateDesktopMessageTokens(UIMessage.user("")))
    }

    @Test
    fun mediaUsesApproximateRequestBudgetsWithoutCountingDataUrlText() {
        assertEquals(1_601, estimateDesktopMessageTokens(UIMessage(role = MessageRole.USER,
            parts = listOf(UIMessagePart.Image(canonicalInlineImageFixture())))))
        assertEquals(1_126, estimateDesktopMessageTokens(UIMessage(role = MessageRole.USER,
            parts = listOf(UIMessagePart.Audio("file:///audio.m4a")))))
        assertEquals(1_126, estimateDesktopMessageTokens(UIMessage(role = MessageRole.USER,
            parts = listOf(UIMessagePart.Video("file:///video.mp4")))))
        assertEquals(22, estimateDesktopMessageTokens(UIMessage(role = MessageRole.USER,
            parts = listOf(UIMessagePart.Document("file:///doc.txt", "doc.txt")))))
    }

    @Test
    fun toolInputsAndNestedOutputsContributeAlongsideReasoning() {
        val message = UIMessage(role = MessageRole.ASSISTANT, parts = listOf(
            UIMessagePart.Reasoning("思考"),
            UIMessagePart.Tool("outer", "lookup", "ABCD", output = listOf(
                UIMessagePart.Tool("inner", "lookup", "中", output = listOf(
                    UIMessagePart.Audio("file:///audio.m4a"), UIMessagePart.Text("东西"),
                )),
            )),
        ))
        assertEquals((9 + 8 + 4 + 4 + 4_500 + 8) / 4, estimateDesktopMessageTokens(message))
        assertEquals(message, DesktopMessage.from(message).toMessage())
        assertEquals(estimateDesktopMessageTokens(message), DesktopMessage.from(message).estimatedTokens)
    }
}
