package app.amber.ai.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

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

    @Test
    fun doubleClickIsExplicitAndOnlyExposedByClick() {
        val click = assertIs<InputSchema.Obj>(createWebMountClickToolDeclaration().parameters())
        val tap = assertIs<InputSchema.Obj>(createWebMountTapToolDeclaration().parameters())
        assertTrue("click_count" in click.properties)
        assertEquals(false, "click_count" in tap.properties)
        assertTrue(createWebMountClickToolDeclaration().description.contains("click_count=2"))
    }

    @Test
    fun visualReadRequiresSessionAndApprovalPath() {
        val tool = createWebMountVisualReadToolDeclaration()
        val parameters = assertIs<InputSchema.Obj>(tool.parameters())

        assertEquals(listOf("session_id"), parameters.required)
        assertEquals(true, "session_id" in parameters.properties)
        assertEquals(true, "question" in parameters.properties)
        assertEquals(true, tool.needsApproval)
        assertEquals(true, tool.mandatoryApproval)
        assertEquals(false, tool.allowsAutoApproval)
        assertTrue(tool.description.contains("wm_visual_snapshot"))
        assertTrue(tool.description.contains("local iOS WKWebView"))
        assertTrue(tool.description.contains("current chat model first"))
        assertTrue(tool.description.contains("auxiliary vision model"))
        assertTrue(tool.description.contains("manual approval or high-risk auto-approval"))
        assertTrue(tool.description.contains("visual verification has not occurred"))
        assertTrue(tool.description.contains("DOM-verifiable results may still be reported honestly"))
    }

    @Test
    fun navigationAndObservationDeclarationsPromptVisualConfirmation() {
        assertTrue(createWebMountOpenToolDeclaration().description.contains("wm_visual_read"))
        assertTrue(createWebMountObserveToolDeclaration().description.contains("wm_visual_read"))
    }

    @Test
    fun sensitiveWebMountDeclarationsDescribeBothApprovalPaths() {
        val tools = listOf(
            createWebMountScreenshotToolDeclaration(),
            createWebMountClearSessionToolDeclaration(),
            createWebMountSiteAddToolDeclaration(),
            createWebMountSiteRemoveToolDeclaration(),
        )

        tools.forEach { tool ->
            assertTrue(
                tool.description.contains("manual approval or high-risk auto-approval"),
                tool.name,
            )
            assertTrue(tool.needsApproval, tool.name)
        }
    }
}
