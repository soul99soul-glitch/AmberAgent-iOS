package app.amber.ai.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class WebMountToolDeclarationsTest {
    @Test
    fun agentMutationDeclarationsRequireBoundSessionAndSnapshot() {
        val tools = listOf(
            createWebMountClickToolDeclaration(),
            createWebMountTapToolDeclaration(),
            createWebMountTypeToolDeclaration(),
            createWebMountKeysToolDeclaration(),
            createWebMountScrollToolDeclaration(),
            createWebMountSelectToolDeclaration()
        )

        tools.forEach { tool ->
            val parameters = assertIs<InputSchema.Obj>(tool.parameters())
            assertEquals(listOf("session_id", "snapshot_id"), parameters.required, tool.name)
            assertEquals(true, "postcondition" in parameters.properties, tool.name)
        }

        val getParameters = assertIs<InputSchema.Obj>(createWebMountGetToolDeclaration().parameters())
        assertEquals(true, "snapshot_id" in getParameters.properties)
    }
}
