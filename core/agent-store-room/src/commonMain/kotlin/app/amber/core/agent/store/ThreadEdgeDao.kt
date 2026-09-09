package app.amber.core.agent.store

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/**
 * P1-c: 线程边存储。数据量小（编排线程的树），建树/递归全部在内存完成：
 * `allEdges()` 一次取全量，`descendantsOf` 按 parent 分组做 BFS 递归。
 */
@Dao
interface ThreadEdgeDao {

    /** 写一条 spawn 边。REPLACE：同一 childThreadId 的重试（同一次逻辑 spawn）
     *  幂等覆盖，不产生重复边。 */
    @Throws(Exception::class)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertEdge(edge: ThreadEdgeEntity)

    @Query("SELECT * FROM thread_edge WHERE child_thread_id = :childThreadId")
    suspend fun edgeFor(childThreadId: String): ThreadEdgeEntity?

    @Query("SELECT * FROM thread_edge WHERE parent_thread_id = :parentThreadId")
    suspend fun childrenOf(parentThreadId: String): List<ThreadEdgeEntity>

    @Throws(Exception::class)
    @Query("SELECT * FROM thread_edge")
    suspend fun allEdges(): List<ThreadEdgeEntity>

    @Query("DELETE FROM thread_edge WHERE child_thread_id IN (:conversationIds)")
    suspend fun deleteEdgesForConversations(conversationIds: List<String>)

    /** Restore only the imported conversations; unrelated local trees stay intact. */
    @Throws(Exception::class)
    @Transaction
    suspend fun restoreEdges(conversationIds: List<String>, edges: List<ThreadEdgeEntity>) {
        deleteEdgesForConversations(conversationIds)
        edges.forEach { insertEdge(it) }
    }

    @Query("UPDATE thread_edge SET status = :status WHERE child_thread_id = :childThreadId")
    suspend fun setStatus(childThreadId: String, status: String): Int

    /** 该 root 的全部后代边（含所有传递子级），BFS 稳定序（parent 分组序）。 */
    @Throws(Exception::class)
    @Transaction
    suspend fun descendantsOf(rootThreadId: String): List<ThreadEdgeEntity> =
        descendantsOf(rootThreadId, allEdges())
}

/** 纯函数：内存建树取 root 的全部后代边（含传递子级）。 */
fun descendantsOf(rootThreadId: String, edges: List<ThreadEdgeEntity>): List<ThreadEdgeEntity> {
    val childrenByParent = edges.groupBy { it.parentThreadId }
    val result = mutableListOf<ThreadEdgeEntity>()
    val queue = ArrayDeque<String>()
    queue.add(rootThreadId)
    while (queue.isNotEmpty()) {
        val parent = queue.removeFirst()
        for (edge in childrenByParent[parent].orEmpty()) {
            result.add(edge)
            queue.add(edge.childThreadId)
        }
    }
    return result
}
