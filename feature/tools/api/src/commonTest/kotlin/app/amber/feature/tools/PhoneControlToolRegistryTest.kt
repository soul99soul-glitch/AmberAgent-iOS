package app.amber.feature.tools

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PhoneControlToolRegistryTest {
    @Test
    fun phoneAddAppRequiresHighRiskApprovalAndCannotAutoApprove() {
        val registry = ToolRegistry.from(
            listOf(
                "phone_status" to "pure",
                "phone_apps" to "pure",
                "phone_add_app" to "sideEffect",
                "phone_observe" to "pure",
                "phone_act" to "sideEffect",
                "phone_run_flow" to "sideEffect",
                "phone_run_goal" to "sideEffect",
            ).map { (name, effect) ->
                createDynamicWorkflowToolDeclaration(
                    toolId = name,
                    version = "1",
                    description = name,
                    inputsJson = """{"type":"object","properties":{},"required":[],"additionalProperties":false}""",
                    effectClass = effect,
                )
            }
        )

        val addAppMetadata = assertNotNull(registry.metadataFor("phone_add_app"))
        val addAppPolicy = assertNotNull(registry.evaluateInvocation("phone_add_app"))
        assertEquals("screen", addAppMetadata.category)
        assertTrue(addAppMetadata.mutates)
        assertEquals(ToolRisk.High, addAppMetadata.risk)
        assertTrue(addAppMetadata.needsApproval)
        assertFalse(addAppMetadata.autoApprovable)
        assertTrue(addAppPolicy.needsApproval)
        assertFalse(addAppPolicy.concurrencySafe)
        assertFalse(addAppPolicy.speculativeEligible)

        for (mutatingName in listOf("phone_act", "phone_run_flow", "phone_run_goal")) {
            val metadata = assertNotNull(registry.metadataFor(mutatingName))
            val policy = assertNotNull(registry.evaluateInvocation(mutatingName))
            assertEquals("screen", metadata.category)
            assertTrue(metadata.mutates)
            assertEquals(ToolRisk.Sensitive, metadata.risk)
            assertTrue(policy.needsApproval)
            assertFalse(policy.concurrencySafe)
            assertFalse(policy.speculativeEligible)
        }

        val observeMetadata = assertNotNull(registry.metadataFor("phone_observe"))
        val observePolicy = assertNotNull(registry.evaluateInvocation("phone_observe"))
        assertEquals("screen", observeMetadata.category)
        assertFalse(observeMetadata.mutates)
        assertTrue(observeMetadata.sensitiveRead)
        assertEquals(ToolRisk.Sensitive, observeMetadata.risk)
        assertFalse(observePolicy.concurrencySafe)
        assertFalse(observePolicy.speculativeEligible)
    }
}
