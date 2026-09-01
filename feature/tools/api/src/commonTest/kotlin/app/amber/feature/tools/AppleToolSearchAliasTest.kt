package app.amber.feature.tools

import app.amber.ai.core.Tool
import app.amber.ai.core.createCalendarEventCreateToolDeclaration
import app.amber.ai.core.createCalendarEventsListToolDeclaration
import app.amber.ai.core.createAlarmScheduleToolDeclaration
import app.amber.ai.core.createHealthSummaryReadToolDeclaration
import app.amber.ai.core.createContactsPickToolDeclaration
import app.amber.ai.core.createJournalingSuggestionPickToolDeclaration
import app.amber.ai.core.createNotificationScheduleToolDeclaration
import app.amber.ai.core.createPhotosPickToolDeclaration
import app.amber.ai.core.createRemindersListToolDeclaration
import app.amber.ai.core.createWeatherReadToolDeclaration
import app.amber.ai.core.createWorkoutPlanPreviewToolDeclaration
import app.amber.ai.core.createWorkoutScheduleToolDeclaration
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertTrue

class AppleToolSearchAliasTest {
    private val tools: List<Tool> = listOf(
        createCalendarEventsListToolDeclaration(),
        createCalendarEventCreateToolDeclaration(),
        createRemindersListToolDeclaration(),
        createNotificationScheduleToolDeclaration(),
        createHealthSummaryReadToolDeclaration(),
        createWeatherReadToolDeclaration(),
        createAlarmScheduleToolDeclaration(),
        createContactsPickToolDeclaration(),
        createPhotosPickToolDeclaration(),
        createJournalingSuggestionPickToolDeclaration(),
        createWorkoutPlanPreviewToolDeclaration(),
        createWorkoutScheduleToolDeclaration(),
    )

    @Test
    fun chineseQueriesDiscoverAppleTools() {
        val index = ToolSearchIndex(ToolRegistry.from(tools), null)
        mapOf(
            "日历" to "calendar_events_list",
            "提醒事项" to "reminders_list",
            "本地通知" to "notification_schedule",
            "睡眠健康" to "health_summary_read",
            "天气预报" to "weather_read",
            "响铃闹钟" to "alarm_schedule",
            "选联系人" to "contacts_pick",
            "选照片" to "photos_pick",
            "日记建议" to "journaling_suggestion_pick",
            "训练方案" to "workout_plan_preview",
            "同步到手表" to "workout_schedule",
        ).forEach { (query, expected) ->
            val expanded = index.searchPayload(query, null, 5)["expanded_tools"]!!
                .jsonArray.map { it.jsonPrimitive.content }
            assertTrue(expected in expanded, "query=$query expected=$expected actual=$expanded")
        }
    }
}
