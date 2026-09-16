package shared

import app.amber.ai.core.ReasoningLevel
import app.amber.core.memory.model.MemoryWorkerSetting
import app.amber.core.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.uuid.Uuid

@OptIn(kotlin.uuid.ExperimentalUuidApi::class)
class IosSettingsMutationsMemoryTest {
    @Test
    fun memoryExtractionSettingsChangeOnlyWorkerSwitches() {
        val originalWorker = MemoryWorkerSetting(
            enabled = true,
            modelId = Uuid.random(),
            followCompressModel = false,
            daydreamModelId = Uuid.random(),
            daydreamFollowCompressModel = false,
            daydreamReasoningLevel = ReasoningLevel.LOW,
            extractionEnabled = true,
            dreamMaintenanceEnabled = false,
            dreamModelEnabled = true,
            dreamEnabled = true,
            runOnlyOnIdle = false,
            runOnlyOnCharging = true,
            maxDailyRuns = 3,
            dreamMaxDailyRuns = 2,
            timeoutMs = 45_000L,
        )
        val settings = Settings(
            agentRuntime = Settings().agentRuntime.copy(memoryWorker = originalWorker)
        )

        val updated = IosSettingsMutations.setMemoryExtractionSettings(
            settings = settings,
            enabled = false,
            runOnlyOnCharging = false,
        )

        val expectedWorker = originalWorker.copy(
            enabled = false,
            extractionEnabled = false,
            runOnlyOnCharging = false,
        )
        assertEquals(settings.agentRuntime.copy(memoryWorker = expectedWorker), updated.agentRuntime)
    }

    @Test
    fun memoryDreamSettingsChangeOnlyDreamSwitches() {
        val originalWorker = MemoryWorkerSetting(
            enabled = true,
            dreamMaintenanceEnabled = true,
            dreamModelEnabled = false,
            runOnlyOnCharging = true,
        )
        val settings = Settings(
            agentRuntime = Settings().agentRuntime.copy(memoryWorker = originalWorker)
        )

        val updated = IosSettingsMutations.setMemoryDreamSettings(
            settings = settings,
            maintenanceEnabled = false,
            modelEnabled = true,
        )

        assertEquals(
            originalWorker.copy(dreamMaintenanceEnabled = false, dreamModelEnabled = true),
            updated.agentRuntime.memoryWorker
        )
    }

    @Test
    fun memoryDreamSettingsKeepUnsetSide() {
        val settings = Settings(
            agentRuntime = Settings().agentRuntime.copy(
                memoryWorker = MemoryWorkerSetting(dreamMaintenanceEnabled = false, dreamModelEnabled = false)
            )
        )

        val updated = IosSettingsMutations.setMemoryDreamSettings(
            settings = settings,
            maintenanceEnabled = null,
            modelEnabled = true,
        )

        assertEquals(false, updated.agentRuntime.memoryWorker.dreamMaintenanceEnabled)
        assertEquals(true, updated.agentRuntime.memoryWorker.dreamModelEnabled)
    }

    @Test
    fun changingChargingSettingKeepsIndependentExtractionSwitches() {
        val originalWorker = MemoryWorkerSetting(enabled = true, extractionEnabled = false)
        val settings = Settings(
            agentRuntime = Settings().agentRuntime.copy(memoryWorker = originalWorker)
        )

        val updated = IosSettingsMutations.setMemoryExtractionSettings(
            settings = settings,
            enabled = null,
            runOnlyOnCharging = false,
        )

        assertEquals(originalWorker.copy(runOnlyOnCharging = false), updated.agentRuntime.memoryWorker)
    }
}
