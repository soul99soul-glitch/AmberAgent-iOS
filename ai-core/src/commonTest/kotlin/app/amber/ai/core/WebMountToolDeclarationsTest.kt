package app.amber.ai.core

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
    fun webMountQueriesAndPostconditionsDeclareNonEmptyStrings() {
        val click = assertIs<InputSchema.Obj>(createWebMountClickToolDeclaration().parameters())
        val postcondition = click.properties["postcondition"]!!.jsonObject
        val postconditionValue = postcondition["properties"]!!.jsonObject["value"]!!.jsonObject
        assertEquals("1", postconditionValue["minLength"]?.jsonPrimitive?.content)
        assertEquals("boolean", postcondition["properties"]!!.jsonObject["require_page_change"]!!.jsonObject["type"]?.jsonPrimitive?.content)
        assertTrue(postcondition["description"]!!.jsonPrimitive.content.contains("ready_state"))
        val postconditionConditions = postcondition["properties"]!!
            .jsonObject["condition"]!!
            .jsonObject["enum"]!!
            .jsonArray
            .map { it.jsonPrimitive.content }
        assertTrue("document_changed" in postconditionConditions)
        assertTrue("url_changed" in postconditionConditions)

        val find = assertIs<InputSchema.Obj>(createWebMountFindToolDeclaration().parameters())
        listOf("selector", "text").forEach { name ->
            val schema = find.properties[name]!!.jsonObject
            assertEquals("1", schema["minLength"]?.jsonPrimitive?.content, name)
        }
    }

    @Test
    fun webMountWaitDeclaresDocumentAndUrlChangeConditions() {
        val wait = assertIs<InputSchema.Obj>(createWebMountWaitToolDeclaration().parameters())
        val condition = wait.properties["condition"]!!.jsonObject
        val values = condition["enum"]!!.jsonArray.map { it.jsonPrimitive.content }

        assertTrue("document_changed" in values)
        assertTrue("url_changed" in values)
        assertTrue("before_document_id" in wait.properties)
        assertTrue("before_url" in wait.properties)
        assertEquals("integer", wait.properties["before_url_revision"]!!.jsonObject["type"]?.jsonPrimitive?.content)
        assertEquals("integer", wait.properties["before_dom_revision"]!!.jsonObject["type"]?.jsonPrimitive?.content)
        assertEquals("boolean", wait.properties["require_page_change"]!!.jsonObject["type"]?.jsonPrimitive?.content)
        assertTrue(wait.properties["before_url_revision"]!!.jsonObject["description"]!!.jsonPrimitive.content.contains("wm_state"))
        assertTrue(wait.properties["require_page_change"]!!.jsonObject["description"]!!.jsonPrimitive.content.contains("business goal"))
        assertTrue(condition["description"]!!.jsonPrimitive.content.contains("readiness only"))

        val observe = assertIs<InputSchema.Obj>(createWebMountObserveToolDeclaration().parameters())
        assertEquals("0", observe.properties["max_chars"]!!.jsonObject["minimum"]!!.jsonPrimitive.content)
        assertEquals("8000", observe.properties["max_chars"]!!.jsonObject["maximum"]!!.jsonPrimitive.content)
        assertEquals("0", observe.properties["max_links"]!!.jsonObject["minimum"]!!.jsonPrimitive.content)
        assertEquals("40", observe.properties["max_links"]!!.jsonObject["maximum"]!!.jsonPrimitive.content)
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
