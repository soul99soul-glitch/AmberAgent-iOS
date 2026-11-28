package app.amber.core.model

import app.amber.ai.ui.UIMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.uuid.Uuid

class ConversationTest {
    @Test
    fun withdrawingDraftAndShiftingFollowupNeverCreatesMixedRoleVariants() {
        val u1 = UIMessage.user("还有什么肉可以吃")
        val a1 = UIMessage.assistant("俺先想想…")
        val u2 = UIMessage.user("在哪有记载？")
        val initial = Conversation.ofId(
            id = Uuid.random(),
            messages = listOf(u1.toMessageNode(), a1.toMessageNode(), u2.toMessageNode()),
        )

        // Intermediate frame where provisional A1 is withdrawn before A2 starts: U2 shifts left without duplicating.
        val afterWithdraw = initial.updateCurrentMessages(listOf(u1, u2))
        assertEquals(listOf(u1.id, u2.id), afterWithdraw.currentMessages.map { it.id })
        assertEquals(listOf(1, 1), afterWithdraw.messageNodes.map { it.messages.size })

        // Direct transition [U1, A1, U2] -> [U1, U2, A2]: neither U2 nor A2 gets a bogus 2/2 variant counter.
        val a2 = UIMessage.assistant("《东京梦华录》里记了不少。")
        val afterReplan = initial.updateCurrentMessages(listOf(u1, u2, a2))
        assertEquals(listOf(u1.id, u2.id, a2.id), afterReplan.currentMessages.map { it.id })
        assertEquals(listOf(1, 1, 1), afterReplan.messageNodes.map { it.messages.size })
        assertSame(initial.messageNodes[0], afterReplan.messageNodes[0])
        assertSame(initial.messageNodes[2], afterReplan.messageNodes[1])
    }

    @Test
    fun sameIndexSameRoleRegenerateStillAppendsSiblingVariantAndPreservesIdentityShortCircuit() {
        val u1 = UIMessage.user("介绍一下北宋饮食")
        val a1 = UIMessage.assistant("第一版回答")
        val initial = Conversation.ofId(
            id = Uuid.random(),
            messages = listOf(u1.toMessageNode(), a1.toMessageNode()),
        )

        // Identity short-circuit returns exact same Conversation instance when unchanged.
        assertSame(initial, initial.updateCurrentMessages(listOf(u1, a1)))

        // Regenerating assistant at the same index with a new ID keeps both variants as 2/2.
        val a2 = UIMessage.assistant("第二版回答")
        val regenerated = initial.updateCurrentMessages(listOf(u1, a2))
        assertEquals(2, regenerated.messageNodes.size)
        assertEquals(1, regenerated.messageNodes[0].messages.size)
        assertEquals(listOf(a1.id, a2.id), regenerated.messageNodes[1].messages.map { it.id })
        assertEquals(1, regenerated.messageNodes[1].selectIndex)
        assertSame(initial.messageNodes[0], regenerated.messageNodes[0])
    }

    @Test
    fun sameIndexDifferentRoleReplacesNodeInsteadOfMixingRoles() {
        val u1 = UIMessage.user("问题一")
        val a1 = UIMessage.assistant("临时草稿")
        val initial = Conversation.ofId(
            id = Uuid.random(),
            messages = listOf(u1.toMessageNode(), a1.toMessageNode()),
        )

        val u2 = UIMessage.user("新追问")
        val updated = initial.updateCurrentMessages(listOf(u1, u2))
        assertEquals(listOf(u1.id, u2.id), updated.currentMessages.map { it.id })
        assertEquals(listOf(1, 1), updated.messageNodes.map { it.messages.size })
    }
}
