package app.amber.core.memory.model

import app.amber.core.model.MemoryKind
import app.amber.core.model.MemoryScope
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class IosMemoryFactoryTopicTest {

    @AfterTest
    fun tearDown() {
        IosMemoryFactory.replaceAll(emptyList())
    }

    @Test
    fun upsertCreatesTopicRecordWithMembers() {
        val topic = IosMemoryFactory.upsertTopicRecord(
            title = "阅读习惯",
            summary = "用户偏好睡前阅读短篇。",
            memberIds = listOf(3, 7, 7),
        )
        assertNotNull(topic)
        assertEquals(MemoryKind.TOPIC, topic.kind)
        assertEquals(MemoryScope.LONG_TERM, topic.scope)
        assertEquals("阅读习惯", topic.topicTitle)
        assertEquals(listOf(3, 7), topic.memberIds)
        assertEquals("用户偏好睡前阅读短篇。", topic.content)
        assertTrue(!topic.archived && !topic.pinned)
    }

    @Test
    fun upsertSameNormalizedTitleUpdatesInPlace() {
        val first = IosMemoryFactory.upsertTopicRecord(
            title = "阅读 习惯",
            summary = "v1",
            memberIds = listOf(1),
        )!!
        val second = IosMemoryFactory.upsertTopicRecord(
            title = "阅读习惯",
            summary = "v2",
            memberIds = listOf(2, 4),
        )!!
        assertEquals(first.id, second.id)
        assertEquals("v2", second.content)
        // 归一化标题相同 → 原地更新且成员并集，不产生第二条 TOPIC 记录。
        assertEquals(listOf(1, 2, 4), second.memberIds)
        assertEquals(1, IosMemoryFactory.getAllRecords().count { it.kind == MemoryKind.TOPIC })
    }

    @Test
    fun upsertRevivesArchivedTopicWithSameTitle() {
        val first = IosMemoryFactory.upsertTopicRecord("主题A", "s", listOf(1))!!
        IosMemoryFactory.setArchived(first.id, archived = true)
        assertTrue(IosMemoryFactory.getAllRecords().first { it.id == first.id }.archived)
        val second = IosMemoryFactory.upsertTopicRecord("主题a", "s2", listOf(2))!!
        // 同名主题在原地复活并保留成员并集，不制造同题墓碑。
        assertEquals(first.id, second.id)
        assertTrue(!second.archived)
        assertEquals(listOf(1, 2), second.memberIds)
        assertEquals(1, IosMemoryFactory.getAllRecords().count { it.kind == MemoryKind.TOPIC })
    }

    @Test
    fun upsertUnchangedSuggestionReturnsNull() {
        val first = IosMemoryFactory.upsertTopicRecord("主题A", "s", listOf(1, 2))!!
        assertNull(IosMemoryFactory.upsertTopicRecord("主题 A", "s", listOf(2, 1)),
            "完全相同的建议必须幂等为空操作")
        assertEquals(first.updatedAt, IosMemoryFactory.getAllRecords().first { it.id == first.id }.updatedAt)
    }

    @Test
    fun upsertRejectsBlankTitle() {
        assertNull(IosMemoryFactory.upsertTopicRecord("   ", "s", listOf(1)))
    }

    @Test
    fun setArchivedFlipsFlagAndBumpsUpdatedAt() {
        val record = IosMemoryFactory.addMemory(
            scope = MemoryScope.LONG_TERM,
            kind = MemoryKind.NOTE,
            content = "x",
        )
        val archived = IosMemoryFactory.setArchived(record.id, archived = true)!!
        assertTrue(archived.archived)
        assertTrue(archived.updatedAt >= record.updatedAt)
        assertNull(IosMemoryFactory.setArchived(999_999, archived = true))
    }
}
