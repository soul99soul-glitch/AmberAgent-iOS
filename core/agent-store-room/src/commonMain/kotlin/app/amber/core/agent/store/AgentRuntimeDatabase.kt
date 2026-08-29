package app.amber.core.agent.store

import androidx.room.ConstructedBy
import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.RoomDatabaseConstructor
import androidx.room.migration.Migration
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.execSQL

@Database(
    entities = [
        AgentRunEntity::class,
        AgentEventEntity::class,
        AgentToolTransactionEntity::class,
        TraceSpanEntity::class,
        PermissionIntentEntity::class,
        MailboxEnvelopeEntity::class,
        ThreadEdgeEntity::class,
    ],
    version = 5,
    exportSchema = true,
)
@ConstructedBy(AgentRuntimeDatabaseConstructor::class)
abstract class AgentRuntimeDatabase : RoomDatabase() {
    abstract fun agentRuntimeDao(): AgentRuntimeDao

    abstract fun mailboxDao(): MailboxDao

    abstract fun threadEdgeDao(): ThreadEdgeDao
}

/**
 * v1 → v2（P1-b）：新增 mailbox_envelope 表。只建新表，不动既有四表——
 * iOS 老设备（agent_run 已在生产账本/恢复/热力图使用）原地升级不丢数据。
 * 双端 builder（iOS `IosDatabaseFactory`、Android `DataSourceModule`）都必须
 * `addMigrations(MIGRATION_1_2)`，否则 Room 在版本不匹配时拒绝打开。
 */
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(connection: SQLiteConnection) {
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `mailbox_envelope` (
                `id` TEXT NOT NULL,
                `author_thread_id` TEXT NOT NULL,
                `recipient_thread_id` TEXT NOT NULL,
                `type` TEXT NOT NULL,
                `payload` TEXT NOT NULL,
                `trigger_turn` INTEGER NOT NULL,
                `parent_turn_id` TEXT,
                `created_at` INTEGER NOT NULL,
                `delivered_at` INTEGER,
                PRIMARY KEY(`id`)
            )
            """.trimIndent(),
        )
        connection.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_mailbox_envelope_recipient_thread_id_delivered_at_created_at` " +
                "ON `mailbox_envelope` (`recipient_thread_id`, `delivered_at`, `created_at`)",
        )
    }
}

/**
 * v2 → v3（P1-c）：新增 thread_edge 表（线程编排 spawn 边）。只建新表，不动
 * mailbox_envelope 与既有四表——P1-b 升级过的老设备原地再升一级不丢数据。
 * 双端 builder（iOS `IosDatabaseFactory`、Android `DataSourceModule`）都必须
 * `addMigrations(MIGRATION_2_3)`，否则 Room 在版本不匹配时拒绝打开。
 */
val MIGRATION_2_3 = object : Migration(2, 3) {
    override fun migrate(connection: SQLiteConnection) {
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `thread_edge` (
                `child_thread_id` TEXT NOT NULL,
                `parent_thread_id` TEXT NOT NULL,
                `agent_path` TEXT NOT NULL,
                `nickname` TEXT,
                `role_assistant_id` TEXT,
                `fork_turns` TEXT NOT NULL,
                `status` TEXT NOT NULL,
                `created_at` INTEGER NOT NULL,
                PRIMARY KEY(`child_thread_id`)
            )
            """.trimIndent(),
        )
        connection.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_thread_edge_parent_thread_id` " +
                "ON `thread_edge` (`parent_thread_id`)",
        )
        connection.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_thread_edge_agent_path` ON `thread_edge` (`agent_path`)",
        )
    }
}

/**
 * v3 → v4: durable envelope fields for the shared Run Protocol. Existing rows
 * are preserved; the two historical active-state wire values are normalized so
 * future compare-and-set transitions use one canonical vocabulary.
 */
val MIGRATION_3_4 = object : Migration(3, 4) {
    override fun migrate(connection: SQLiteConnection) {
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `terminal_reason` TEXT")
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `provider_id` TEXT")
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `model_id` TEXT")
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `prompt_version` TEXT")
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `tool_catalog_version` TEXT")
        connection.execSQL("ALTER TABLE `agent_run` ADD COLUMN `capability_snapshot` TEXT")
        connection.execSQL("ALTER TABLE `agent_event` ADD COLUMN `turn_id` TEXT")
        connection.execSQL("ALTER TABLE `agent_event` ADD COLUMN `step_id` TEXT")
        connection.execSQL("ALTER TABLE `agent_event` ADD COLUMN `tool_call_id` TEXT")
        connection.execSQL("UPDATE `agent_run` SET `terminal_reason` = `interrupted_reason` WHERE `finished_at` IS NOT NULL")
        connection.execSQL("UPDATE `agent_run` SET `status` = 'waiting_user' WHERE `status` = 'awaiting_permission'")
        connection.execSQL("UPDATE `agent_run` SET `status` = 'resumable' WHERE `status` = 'recovery_pending'")
    }
}

/** v4 → v5: add the per-tool compare-and-set execution head. */
val MIGRATION_4_5 = object : Migration(4, 5) {
    override fun migrate(connection: SQLiteConnection) {
        connection.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `agent_tool_transaction` (
                `run_id` TEXT NOT NULL,
                `tool_call_id` TEXT NOT NULL,
                `tool_name` TEXT NOT NULL,
                `args_digest` TEXT NOT NULL,
                `effect_class` TEXT NOT NULL,
                `state` TEXT NOT NULL,
                `outcome` TEXT,
                `result_payload` TEXT,
                `updated_at` INTEGER NOT NULL,
                PRIMARY KEY(`run_id`, `tool_call_id`)
            )
            """.trimIndent(),
        )
        connection.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_agent_tool_transaction_run_id` " +
                "ON `agent_tool_transaction` (`run_id`)",
        )
        connection.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_agent_tool_transaction_state` " +
                "ON `agent_tool_transaction` (`state`)",
        )
    }
}

@Suppress("NO_ACTUAL_FOR_EXPECT")
expect object AgentRuntimeDatabaseConstructor : RoomDatabaseConstructor<AgentRuntimeDatabase>
