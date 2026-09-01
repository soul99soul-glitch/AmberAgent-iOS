package app.amber.ai.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AppleToolDeclarationTest {
    @Test
    fun eventKitMutationsAreDeclaredAndAlwaysRequireApproval() {
        val names = listOf(
            "calendar_event_create",
            "calendar_event_update",
            "calendar_event_delete",
            "reminder_create",
            "reminder_update",
            "reminder_delete",
            "reminder_complete",
        )
        val tools = iosToolDeclarations(names)

        assertEquals(names, tools.map { it.name })
        tools.forEach { tool ->
            assertTrue(tool.needsApproval, tool.name)
            assertTrue(tool.mandatoryApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, tool.name)
        }
    }

    @Test
    fun eventKitReadResultsCanFeedIdentifierBasedMutations() {
        val names = listOf(
            "calendar_events_list",
            "calendar_event_update",
            "calendar_event_delete",
            "reminders_list",
            "reminder_update",
            "reminder_delete",
        )

        assertEquals(names, iosToolDeclarations(names).map { it.name })
    }

    @Test
    fun sensitiveAppleReadsAndNotificationsAlsoRequireFreshApproval() {
        val names = listOf(
            "health_summary_read",
            "calendar_events_list",
            "reminders_list",
            "notification_schedule",
            "notification_cancel",
            "alarm_schedule",
            "alarms_list",
            "alarm_cancel",
        )

        iosToolDeclarations(names).forEach { tool ->
            assertTrue(tool.needsApproval, tool.name)
            assertTrue(tool.mandatoryApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, tool.name)
        }
    }

    @Test
    fun pickerFirstPersonalContextUsesSystemHandoffInsteadOfGenericApproval() {
        val names = listOf("contacts_pick", "photos_pick", "journaling_suggestion_pick")
        val tools = iosToolDeclarations(names)

        assertEquals(names, tools.map { it.name })
        tools.forEach { tool ->
            assertFalse(tool.needsApproval, tool.name)
            assertFalse(tool.mandatoryApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, tool.name)
        }
    }

    @Test
    fun workoutPreviewIsLocalButSchedulingAndRemovalRequireApproval() {
        val preview = iosToolDeclaration("workout_plan_preview")!!
        assertFalse(preview.needsApproval)

        val gated = iosToolDeclarations(
            listOf("workout_schedule", "workouts_scheduled_list", "workout_scheduled_remove"),
        )
        gated.forEach { tool ->
            assertTrue(tool.needsApproval, tool.name)
            assertTrue(tool.mandatoryApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, tool.name)
        }
    }
}
