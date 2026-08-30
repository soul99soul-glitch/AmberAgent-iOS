package app.amber.ai.core

import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TerminalToolDeclarationTest {
    @Test
    fun terminalExecutePinsForegroundNonPtyContract() {
        val tool = createTerminalExecuteToolDeclaration()

        assertEquals("terminal_execute", tool.name)
        assertTrue(tool.needsApproval)
        assertTrue(tool.mandatoryApproval)
        assertFalse(tool.allowsAutoApproval)
        assertTrue("non-interactive" in tool.description)
        assertTrue("does not allocate a PTY" in tool.description)

        val parameters = tool.parameters()
        assertIs<InputSchema.Obj>(parameters)
        assertEquals(listOf("command"), parameters.required)
        assertEquals(
            "string",
            parameters.properties["command"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull
        )
        assertTrue("profile_id" in parameters.properties)
        assertTrue("timeout_seconds" in parameters.properties)
        assertTrue("purpose" in parameters.properties)
        assertTrue("cwd" in parameters.properties)
    }

    @Test
    fun terminalExecuteIsAvailableFromIosDeclarationRegistry() {
        assertEquals("terminal_execute", iosToolDeclaration("terminal_execute")?.name)
        val embedded = createIosIshExecuteToolDeclaration()
        val parameters = embedded.parameters() as InputSchema.Obj
        assertTrue("cwd" in parameters.properties)
        assertTrue("background" in parameters.properties)
        assertEquals(
            "boolean",
            parameters.properties["background"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull
        )
        assertEquals(
            "32000",
            parameters.properties["script"]!!.jsonObject["maxLength"]?.jsonPrimitive?.contentOrNull
        )
        assertTrue("process-local" in embedded.description)
        assertTrue("no stdin" in embedded.description)
    }

    @Test
    fun terminalJobDeclarationsPinApprovalAndObserverBoundaries() {
        val start = createTerminalJobStartToolDeclaration()
        val read = createTerminalJobReadToolDeclaration()
        val wait = createTerminalJobWaitToolDeclaration()
        val stop = createTerminalJobStopToolDeclaration()

        assertTrue(start.mandatoryApproval)
        assertTrue(stop.mandatoryApproval)
        assertFalse(read.needsApproval)
        assertFalse(wait.needsApproval)
        assertTrue("non-PTY" in start.description)
        assertTrue("never stops" in wait.description)
        assertTrue("embedded iSH" in read.description)
        assertTrue("embedded iSH" in stop.description)
        assertTrue("cwd" in (start.parameters() as InputSchema.Obj).properties)

        listOf(start, read, wait, stop).forEach { tool ->
            assertEquals(tool.name, iosToolDeclaration(tool.name)?.name)
        }
        assertEquals(listOf("job_id"), (read.parameters() as InputSchema.Obj).required)
        assertTrue("wait_timeout_seconds" in (wait.parameters() as InputSchema.Obj).properties)
    }
}
