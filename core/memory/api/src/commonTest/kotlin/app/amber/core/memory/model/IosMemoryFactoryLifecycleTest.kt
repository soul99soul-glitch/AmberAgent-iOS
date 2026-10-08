package app.amber.core.memory.model

import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class IosMemoryFactoryLifecycleTest {

    @AfterTest
    fun tearDown() {
        IosMemoryFactory.replaceAll(emptyList())
    }

    private fun record(
        id: Int,
        kind: MemoryKind = MemoryKind.USER,
        archived: Boolean = false,
        expiresAt: Long? = null,
        memberIds: List<Int> = emptyList(),
    ) = MemoryRecord(
        id = id,
        content = "记忆 $id",
        scope = MemoryScope.SHORT_TERM,
        kind = kind,
        assistantId = IosMemoryFactory.SHORT_TERM_MEMORY_ID,
        expiresAt = expiresAt,
        archived = archived,
        createdAt = 10,
        updatedAt = 20,
        memberIds = memberIds,
    )

    @Test
    fun reinforceSetsUsageAndReinforcementWithoutTouchingUpdatedAt() {
        IosMemoryFactory.replaceAll(listOf(record(1), record(2)))

        IosMemoryFactory.reinforceMemories(listOf(1), timestamp = 500)

        val byId = IosMemoryFactory.getAllRecords().associateBy { it.id }
        assertEquals(500, byId.getValue(1).lastReinforcedAt)
        assertEquals(500, byId.getValue(1).lastUsedAt)
        assertEquals(20, byId.getValue(1).updatedAt)
        assertNull(byId.getValue(2).lastReinforcedAt)
    }

    @Test
    fun replaceTopicMemberKeepsOrderAndDeduplicates() {
        IosMemoryFactory.replaceAll(
            listOf(
                record(9, kind = MemoryKind.TOPIC, memberIds = listOf(1, 2, 3)),
                record(10, kind = MemoryKind.TOPIC, memberIds = listOf(3, 4)),
                record(11, kind = MemoryKind.TOPIC, memberIds = listOf(5)),
            ),
        )

        IosMemoryFactory.replaceTopicMember(oldId = 1, newId = 3)

        val byId = IosMemoryFactory.getAllRecords().associateBy { it.id }
        assertEquals(listOf(3, 2), byId.getValue(9).memberIds)
        assertEquals(listOf(3, 4), byId.getValue(10).memberIds)
        assertEquals(20, byId.getValue(10).updatedAt, "untouched topics keep updatedAt")
    }

    @Test
    fun mergeNearDuplicateArchivesLoserAndFoldsProvenanceIntoWinner() {
        IosMemoryFactory.replaceAll(
            listOf(
                record(1).copy(sourceMessageIds = listOf("m1"), lastReinforcedAt = 300, createdAt = 5),
                record(2).copy(sourceMessageIds = listOf("m2"), lastUsedAt = 400, expiresAt = 9_000),
                record(9, kind = MemoryKind.TOPIC, memberIds = listOf(1, 7)),
                record(3, archived = true),
            ),
        )

        assertTrue(IosMemoryFactory.mergeNearDuplicate(winnerId = 2, loserId = 1, now = 1_000))

        val byId = IosMemoryFactory.getAllRecords().associateBy { it.id }
        assertTrue(byId.getValue(1).archived, "loser is archived, not deleted")
        val winner = byId.getValue(2)
        assertEquals(listOf(1), winner.supersedesIds)
        assertEquals(listOf("m2", "m1"), winner.sourceMessageIds)
        assertEquals(10, winner.createdAt, "winner keeps its own recorded time")
        assertNull(winner.expiresAt, "a permanent loser keeps the merged fact permanent")
        assertEquals(400, winner.lastUsedAt)
        assertEquals(300, winner.lastReinforcedAt)
        assertEquals(listOf(2, 7), byId.getValue(9).memberIds)
        assertFalse(IosMemoryFactory.mergeNearDuplicate(winnerId = 2, loserId = 3, now = 1_000), "archived loser")
        assertFalse(IosMemoryFactory.mergeNearDuplicate(winnerId = 2, loserId = 9, now = 1_000), "topic loser")
    }

    @Test
    fun restoreClearsPastExpiryKeepsFutureExpiryAndRejectsTopicsAndLiveRecords() {
        IosMemoryFactory.replaceAll(
            listOf(
                record(1, archived = true, expiresAt = 100),
                record(2, archived = true, expiresAt = 5_000),
                record(3, kind = MemoryKind.TOPIC, archived = true),
                record(4),
            ),
        )

        val expired = assertNotNull(IosMemoryFactory.restoreMemory(1, now = 1_000))
        val future = assertNotNull(IosMemoryFactory.restoreMemory(2, now = 1_000))

        assertFalse(expired.archived)
        assertNull(expired.expiresAt, "restoring an expired record clears the stale expiry")
        assertEquals(1_000, expired.updatedAt)
        assertEquals(5_000, future.expiresAt)
        assertNull(IosMemoryFactory.restoreMemory(3, now = 1_000), "topics are owned by maintenance")
        assertNull(IosMemoryFactory.restoreMemory(4, now = 1_000), "live records have nothing to restore")
    }
}
