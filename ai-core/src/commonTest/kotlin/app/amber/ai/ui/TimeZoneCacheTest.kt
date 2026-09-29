package app.amber.ai.ui

import kotlinx.datetime.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * P3a: `currentSystemTimeZoneCached()` short-caches `TimeZone.currentSystemDefault()`
 * (see [CachedSystemTimeZone] in Message.kt) so `UIMessage` construction stops
 * re-parsing the platform timezone database on every message. The cache must
 * stay observationally identical to a direct call.
 */
class TimeZoneCacheTest {
    @Test
    fun cachedZoneMatchesDirectSystemZoneCall() {
        assertEquals(TimeZone.currentSystemDefault(), currentSystemTimeZoneCached())
    }

    @Test
    fun repeatedCallsWithinValidityWindowReturnTheSameZone() {
        val first = currentSystemTimeZoneCached()
        val second = currentSystemTimeZoneCached()
        val third = currentSystemTimeZoneCached()
        assertEquals(first, second)
        assertEquals(second, third)
    }
}
