package app.amber.ai.core

import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * `ssh_profile_*` agent declarations.
 *
 * The list tool is read-only and needs no approval; the three writers must be
 * non-auto-approvable so an ordinary "auto approve" policy cannot run them.
 * Approval itself is a host (iOS) decision — high-risk auto-approve still runs
 * them there, which is why `mandatoryApproval` stays false.
 */
class SSHProfileToolDeclarationTest {
    private val writerNames = listOf(
        "ssh_profile_create",
        "ssh_profile_update",
        "ssh_profile_delete",
    )

    private val keyWriterNames = listOf(
        "ssh_key_generate",
        "ssh_key_import",
        "ssh_key_delete",
    )

    @Test
    fun listIsReadOnlyAndRequiresNoApproval() {
        val tool = createSSHProfileListToolDeclaration()

        assertEquals("ssh_profile_list", tool.name)
        assertFalse(tool.needsApproval)
        assertTrue(tool.allowsAutoApproval)
        assertFalse(tool.mandatoryApproval)
        assertTrue("never returned" in tool.description)

        val parameters = tool.parameters()
        assertIs<InputSchema.Obj>(parameters)
        assertTrue(parameters.properties.isEmpty(), "list 不接受参数")
        assertTrue(parameters.required.isNullOrEmpty())
    }

    @Test
    fun writersAreDeclaredNonAutoApprovable() {
        val tools = iosToolDeclarations(writerNames)

        assertEquals(writerNames, tools.map { it.name })
        tools.forEach { tool ->
            assertTrue(tool.needsApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, "${tool.name} 必须拒绝普通自动批准")
            // Host keeps the high-risk auto-approve switch authoritative, so the
            // declaration must not be "mandatory approval only".
            assertFalse(tool.mandatoryApproval, tool.name)
        }
    }

    @Test
    fun createDeclaresRequiredEndpointFieldsAndWriteOnlyCredential() {
        val tool = createSSHProfileCreateToolDeclaration()
        val parameters = tool.parameters()
        assertIs<InputSchema.Obj>(parameters)

        assertEquals(listOf("host", "username"), parameters.required)
        listOf("name", "host", "username", "auth_method", "key_id", "jump_profile_id", "password", "private_key", "passphrase").forEach {
            assertNotNull(parameters.properties[it], "缺少字段 $it")
            assertEquals(
                "string",
                parameters.properties[it]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull ?: "",
                "create.$it 应为 string",
            )
        }
        // port 是整数（1-65535 在描述里）
        assertNotNull(parameters.properties["port"], "缺少字段 port")
        assertEquals(
            "integer",
            parameters.properties["port"]!!.jsonObject["type"]?.jsonPrimitive?.contentOrNull,
        )
        assertTrue("never echoed" in tool.description, tool.description)
        assertTrue("ssh_key_generate" in tool.description, tool.description)
    }

    @Test
    fun updateRequiresProfileIdAndAllowsPartialFields() {
        val tool = createSSHProfileUpdateToolDeclaration()
        val parameters = tool.parameters()
        assertIs<InputSchema.Obj>(parameters)

        assertEquals(listOf("profile_id"), parameters.required)
        listOf("profile_id", "name", "host", "port", "username", "auth_method", "key_id", "jump_profile_id", "password", "private_key", "passphrase")
            .forEach { assertNotNull(parameters.properties[it], "缺少字段 $it") }
        assertTrue("Only provided fields change" in tool.description)
        assertTrue("clears the stored credential" in tool.description)
    }

    @Test
    fun deleteRequiresOnlyProfileId() {
        val tool = createSSHProfileDeleteToolDeclaration()
        val parameters = tool.parameters()
        assertIs<InputSchema.Obj>(parameters)

        assertEquals(listOf("profile_id"), parameters.required)
        assertEquals(setOf("profile_id"), parameters.properties.keys)
        assertTrue("destructive" in tool.description)
    }

    @Test
    fun allFourDeclarationsAreAvailableFromTheIosRegistry() {
        val names = listOf("ssh_profile_list").plus(writerNames)
        val tools = iosToolDeclarations(names)

        assertEquals(names, tools.map { it.name })
        names.forEach { name -> assertEquals(name, iosToolDeclaration(name)?.name) }
        assertTrue(names.all { it in iosToolDeclarationNames() }, "声明必须进入 iOS 目录")
    }

    @Test
    fun sshKeyToolsAreDeclaredWithHighRiskApprovalAndWorkflowGuidance() {
        val keyList = createSSHKeyListToolDeclaration()
        assertEquals("ssh_key_list", keyList.name)
        assertFalse(keyList.needsApproval)
        assertTrue(keyList.allowsAutoApproval)
        assertFalse(keyList.mandatoryApproval)
        assertTrue("never returned" in keyList.description)

        val writers = iosToolDeclarations(keyWriterNames)
        assertEquals(keyWriterNames, writers.map { it.name })
        writers.forEach { tool ->
            assertTrue(tool.needsApproval, tool.name)
            assertFalse(tool.allowsAutoApproval, "${tool.name} 必须拒绝普通自动批准")
            assertFalse(tool.mandatoryApproval, tool.name)
        }

        val generate = createSSHKeyGenerateToolDeclaration()
        val genParams = generate.parameters()
        assertIs<InputSchema.Obj>(genParams)
        assertEquals(listOf("name"), genParams.required)
        assertNotNull(genParams.properties["type"])
        assertNotNull(genParams.properties["require_user_presence"])
        assertTrue("authorized_keys" in generate.description)

        val importTool = createSSHKeyImportToolDeclaration()
        val importParams = importTool.parameters()
        assertIs<InputSchema.Obj>(importParams)
        assertEquals(listOf("name", "private_key"), importParams.required)
        assertNotNull(importParams.properties["passphrase"])

        val deleteTool = createSSHKeyDeleteToolDeclaration()
        val deleteParams = deleteTool.parameters()
        assertIs<InputSchema.Obj>(deleteParams)
        assertEquals(listOf("key_id"), deleteParams.required)
        assertTrue("key_in_use" in deleteTool.description)

        val allKeyNames = listOf("ssh_key_list").plus(keyWriterNames)
        assertTrue(allKeyNames.all { it in iosToolDeclarationNames() })
    }
}
