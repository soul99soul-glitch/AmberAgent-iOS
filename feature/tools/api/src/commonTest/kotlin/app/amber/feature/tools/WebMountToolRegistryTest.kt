package app.amber.feature.tools

import app.amber.ai.core.iosToolDeclarations
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class WebMountToolRegistryTest {
    @Test
    fun scrollUsesTheSameMutatingPolicyAsOtherPageActions() {
        val registry = ToolRegistry.from(iosToolDeclarations(listOf("wm_scroll")))
        val metadata = assertNotNull(registry.metadataFor("wm_scroll"))
        val policy = assertNotNull(registry.evaluateInvocation("wm_scroll"))

        assertTrue(metadata.mutates)
        assertEquals(ToolRisk.Sensitive, metadata.risk)
        assertTrue(policy.mutates)
        assertTrue(policy.needsApproval)
        assertFalse(policy.concurrencySafe)
        assertFalse(policy.speculativeEligible)
    }
}
