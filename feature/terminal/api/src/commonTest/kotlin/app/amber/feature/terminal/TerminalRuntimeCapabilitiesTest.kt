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
        assertEquals("local_ios_tools", TerminalRuntimeKind.LOCAL_IOS_TOOLS.wireName)
        assertEquals(TerminalRuntimeTier.STABLE, localTools.tier)
        assertFalse(localTools.supportsPty)
        assertFalse(localTools.supportsPackageInstall)
        assertFalse(localTools.supportsLongRunningJobs)
        assertFalse(localTools.supportsInteractiveLogin)
        assertTrue(localTools.supportsFileSync)
        assertTrue(localTools.appStoreSafeByDefault)
        assertFalse(localTools.supportsExternalCliByDefault)
        assertTrue(localTools.summary.contains("AmberShell"))
        assertTrue(localTools.summary.contains("/workspace"))
        assertTrue(localTools.summary.contains("file and text commands"))
        assertTrue(localTools.summary.contains("without PTY"))
        assertTrue(localTools.summary.contains("printf"))
        assertTrue(localTools.summary.contains("CPython 3.14"))
        assertTrue(localTools.summary.contains("cooperative"))
        assertTrue(localTools.summary.contains("cannot be force-terminated"))
        assertTrue(localTools.summary.contains("python -c"))
        assertTrue(localTools.summary.contains("ExperimentalGPL"))
        assertTrue(localTools.summary.contains("three pipeline stages"))
        assertTrue(localTools.summary.contains("2>"))
        assertTrue(localTools.summary.contains("command substitution"))

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
