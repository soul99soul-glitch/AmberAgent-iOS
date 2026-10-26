package shared

import app.amber.core.settings.Settings
import app.amber.search.SearchServiceOptions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.uuid.Uuid

@OptIn(kotlin.uuid.ExperimentalUuidApi::class)
class IosSettingsMutationsSearchTest {
    @Test
    fun deletingAnEarlierServicePreservesTheSelectedService() {
        val first = SearchServiceOptions.BraveOptions()
        val selected = SearchServiceOptions.TavilyOptions()
        val last = SearchServiceOptions.ExaOptions()
        val settings = Settings(
            searchServices = listOf(first, selected, last),
            searchServiceSelected = 1,
            searchEnabledServiceIds = listOf(first.id, selected.id, last.id),
        )

        val updated = IosSettingsMutations.removeSearchService(settings, first.id.toString())

        assertEquals(listOf(selected, last), updated.searchServices)
        assertEquals(selected.id, updated.searchServices[updated.searchServiceSelected].id)
        assertEquals(listOf(selected.id, last.id), updated.searchEnabledServiceIds)
    }

    @Test
    fun deletingTheOnlyEnabledServiceDoesNotEnableADisabledService() {
        val enabled = SearchServiceOptions.BraveOptions()
        val disabled = SearchServiceOptions.TavilyOptions()
        val settings = Settings(
            searchServices = listOf(enabled, disabled),
            searchServiceSelected = 0,
            searchEnabledServiceIds = listOf(enabled.id),
        )

        val updated = IosSettingsMutations.removeSearchService(settings, enabled.id.toString())

        assertEquals(listOf(disabled), updated.searchServices)
        assertEquals(0, updated.searchServiceSelected)
        assertEquals(emptyList(), updated.searchEnabledServiceIds)
    }

    @Test
    fun deletingADisabledServicePreservesAnExplicitlyEmptyEnabledList() {
        val removed = SearchServiceOptions.BraveOptions()
        val remaining = SearchServiceOptions.TavilyOptions()
        val settings = Settings(
            searchServices = listOf(removed, remaining),
            searchServiceSelected = 1,
            searchEnabledServiceIds = emptyList(),
        )

        val updated = IosSettingsMutations.removeSearchService(settings, removed.id.toString())

        assertEquals(remaining.id, updated.searchServices[updated.searchServiceSelected].id)
        assertEquals(emptyList(), updated.searchEnabledServiceIds)
    }

    @Test
    fun deletingTheSelectedServiceChoosesTheNextNeighborOrPreviousAtTheEnd() {
        val first = SearchServiceOptions.BraveOptions()
        val middle = SearchServiceOptions.TavilyOptions()
        val last = SearchServiceOptions.ExaOptions()
        val settings = Settings(
            searchServices = listOf(first, middle, last),
            searchServiceSelected = 1,
            searchEnabledServiceIds = listOf(first.id, middle.id, last.id),
        )

        val withoutMiddle = IosSettingsMutations.removeSearchService(settings, middle.id.toString())
        val withoutLast = IosSettingsMutations.removeSearchService(withoutMiddle, last.id.toString())

        assertEquals(last.id, withoutMiddle.searchServices[withoutMiddle.searchServiceSelected].id)
        assertEquals(first.id, withoutLast.searchServices[withoutLast.searchServiceSelected].id)
    }

    @Test
    fun deletingTheLastRemainingServiceLeavesAnEmptySelection() {
        val service = SearchServiceOptions.BraveOptions()
        val settings = Settings(
            searchServices = listOf(service),
            searchServiceSelected = 0,
            searchEnabledServiceIds = listOf(service.id),
        )

        val updated = IosSettingsMutations.removeSearchService(settings, service.id.toString())

        assertEquals(emptyList(), updated.searchServices)
        assertEquals(0, updated.searchServiceSelected)
        assertEquals(emptyList(), updated.searchEnabledServiceIds)
    }

    @Test
    fun deletingAnUnknownServiceIsANoOp() {
        val service = SearchServiceOptions.BraveOptions()
        val settings = Settings(
            searchServices = listOf(service),
            searchServiceSelected = 0,
            searchEnabledServiceIds = emptyList(),
        )

        val updated = IosSettingsMutations.removeSearchService(settings, Uuid.random().toString())

        assertSame(settings, updated)
    }
}
