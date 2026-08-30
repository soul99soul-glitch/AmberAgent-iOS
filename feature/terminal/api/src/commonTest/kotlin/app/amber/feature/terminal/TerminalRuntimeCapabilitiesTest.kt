package app.amber.feature.terminal

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TerminalRuntimeCapabilitiesTest {
    @Test
    fun iosCapabilitiesDescribeCurrentlyImplementedProductPaths() {
        assertEquals(
            listOf(
                TerminalRuntimeKind.REMOTE_SSH,
                TerminalRuntimeKind.LOCAL_IOS_TOOLS,
                TerminalRuntimeKind.REMOTE_MOSH,
                TerminalRuntimeKind.ISH_EXPERIMENTAL,
            ),
            TerminalRuntimeCapabilities.iosRuntimes,
        )

        val remoteSSH = TerminalRuntimeCapabilities.forRuntime(TerminalRuntimeKind.REMOTE_SSH)
        assertFalse(remoteSSH.supportsPty)
        assertTrue(remoteSSH.supportsLongRunningJobs)
        assertFalse(remoteSSH.supportsInteractiveLogin)

        val localTools = TerminalRuntimeCapabilities.forRuntime(TerminalRuntimeKind.LOCAL_IOS_TOOLS)
        assertFalse(localTools.supportsFileSync)

        val remoteMosh = TerminalRuntimeCapabilities.forRuntime(TerminalRuntimeKind.REMOTE_MOSH)
        assertFalse(remoteMosh.supportsPty)
        assertFalse(remoteMosh.supportsPackageInstall)
        assertFalse(remoteMosh.supportsLongRunningJobs)
        assertFalse(remoteMosh.supportsInteractiveLogin)

        val embeddedIsh = TerminalRuntimeCapabilities.forRuntime(TerminalRuntimeKind.ISH_EXPERIMENTAL)
        assertTrue(embeddedIsh.supportsPty)
        assertTrue(embeddedIsh.supportsPackageInstall)
        assertTrue(embeddedIsh.supportsLongRunningJobs)
        assertTrue(embeddedIsh.supportsInteractiveLogin)
        assertFalse(embeddedIsh.supportsFileSync)
        assertFalse(embeddedIsh.supportsExternalCliByDefault)
    }
}
