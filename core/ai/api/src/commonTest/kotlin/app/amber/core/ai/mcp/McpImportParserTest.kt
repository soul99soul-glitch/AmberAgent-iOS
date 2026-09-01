package app.amber.core.ai.mcp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class McpImportParserTest {
    @Test
    fun parsesSseAndStreamableHttpServers() {
        val servers = parseMcpServersFromJson(
            """
            {
              "mcpServers": {
                "docs": {
                  "type": "sse",
                  "url": "https://example.com/sse",
                  "headers": {
                    "Authorization": "Bearer token"
                  }
                },
                "search": {
                  "url": "https://example.com/mcp"
                }
              }
            }
            """.trimIndent()
        )

        assertEquals(2, servers.size)

        val docs = assertIs<McpServerConfig.SseTransportServer>(servers[0])
        assertEquals("docs", docs.commonOptions.name)
        assertEquals("https://example.com/sse", docs.url)
        assertEquals(listOf("Authorization" to "Bearer token"), docs.commonOptions.headers)

        val search = assertIs<McpServerConfig.StreamableHTTPServer>(servers[1])
        assertEquals("search", search.commonOptions.name)
        assertEquals("https://example.com/mcp", search.url)
        assertEquals(emptyList(), search.commonOptions.headers)
    }

    @Test
    fun normalizesSupportedTypeAndTransportAliases() {
        data class Case(
            val field: String,
            val value: String,
            val expectedType: String,
        )

        listOf(
            Case("type", "sse", "sse"),
            Case("transport", "sse", "sse"),
            Case("type", "streamable_http", "streamable_http"),
            Case("transport", "streamableHttp", "streamable_http"),
            Case("type", "streamable-http", "streamable_http"),
            Case("transport", " SSE ", "sse"),
            Case("type", " STREAMABLE-HTTP ", "streamable_http"),
        ).forEach { case ->
            val server = parseMcpServersFromJson(
                """
                {"mcpServers":{"server":{"${case.field}":"${case.value}","url":"https://example.com/mcp"}}}
                """.trimIndent()
            ).single()

            assertEquals(case.expectedType, server.transportType, case.toString())
        }
    }

    @Test
    fun acceptsAgreeingTypeAndTransportAndRejectsConflicts() {
        data class Case(
            val type: String,
            val transport: String,
            val expectedType: String?,
        )

        listOf(
            Case("sse", "SSE", "sse"),
            Case("streamable_http", "streamable-http", "streamable_http"),
            Case("sse", "streamable_http", null),
            Case("streamable-http", "sse", null),
        ).forEach { case ->
            val servers = parseMcpServersFromJson(
                """
                {"mcpServers":{"server":{"type":"${case.type}","transport":"${case.transport}","url":"https://example.com/mcp"}}}
                """.trimIndent()
            )

            if (case.expectedType == null) {
                assertEquals(emptyList(), servers, case.toString())
            } else {
                assertEquals(case.expectedType, servers.single().transportType, case.toString())
            }
        }
    }

    @Test
    fun skipsEntriesWithUnknownExplicitTransportValues() {
        data class Case(val field: String, val value: String)

        listOf(
            Case("type", "stdio"),
            Case("transport", "websocket"),
            Case("transport", ""),
            Case("type", "  "),
        ).forEach { case ->
            val servers = parseMcpServersFromJson(
                """
                {"mcpServers":{"server":{"${case.field}":"${case.value}","url":"https://example.com/mcp"}}}
                """.trimIndent()
            )

            assertEquals(emptyList(), servers, case.toString())
        }
    }

    @Test
    fun skipsInvalidEntriesAndKeepsValidTransportEntries() {
        val servers = parseMcpServersFromJson(
            """
            {
              "mcpServers": {
                "sse": {"transport": "sse", "url": "https://example.com/sse"},
                "conflict": {"type": "sse", "transport": "streamable_http", "url": "https://example.com/conflict"},
                "unknown": {"transport": "websocket", "url": "https://example.com/unknown"},
                "http": {"type": "streamableHttp", "url": "https://example.com/http"}
              }
            }
            """.trimIndent()
        )

        assertEquals(listOf("sse", "http"), servers.map { it.commonOptions.name })
        assertEquals(listOf("sse", "streamable_http"), servers.map { it.transportType })
    }

    @Test
    fun reportsPerEntryTransportErrorsWithoutDroppingValidDiagnostics() {
        val result = parseMcpServersWithDiagnostics(
            """
            {
              "mcpServers": {
                "sse": {"transport": "sse", "url": "https://example.com/sse"},
                "conflict": {"type": "sse", "transport": "streamable_http", "url": "https://example.com/conflict"},
                "unknown": {"transport": "websocket", "url": "https://example.com/unknown"},
                "http": {"type": "streamableHttp", "url": "https://example.com/http"}
              }
            }
            """.trimIndent()
        )

        assertEquals(listOf("sse", "http"), result.servers.map { it.commonOptions.name })
        assertEquals(
            listOf(
                McpImportParseError("conflict", "conflicting_transport", "MCP server type and transport disagree"),
                McpImportParseError("unknown", "unsupported_transport", "Unsupported MCP server transport: websocket"),
            ),
            result.errors,
        )
    }

    @Test
    fun reportsDocumentErrorsInsteadOfReturningAnAmbiguousEmptyResult() {
        assertEquals(
            listOf(McpImportParseError("", "invalid_json", "MCP JSON is invalid")),
            parseMcpServersWithDiagnostics("{").errors,
        )
        assertEquals(
            listOf(McpImportParseError("", "missing_mcp_servers", "MCP JSON is missing mcpServers")),
            parseMcpServersWithDiagnostics("{}").errors,
        )
        assertEquals(
            listOf(McpImportParseError("", "invalid_mcp_servers", "mcpServers must be an object")),
            parseMcpServersWithDiagnostics("""{"mcpServers": []}""").errors,
        )
    }

    @Test
    fun returnsEmptyListWhenMcpServersSectionIsMissing() {
        assertEquals(emptyList(), parseMcpServersFromJson("{}"))
    }

    @Test
    fun returnsEmptyListForIncompleteEditorText() {
        listOf(
            "",
            "{",
            "[]",
            """{"mcpServers":"not-an-object"}""",
        ).forEach { text ->
            assertEquals(emptyList(), parseMcpServersFromJson(text), text)
        }
    }

    @Test
    fun skipsMalformedServerAndKeepsValidEntries() {
        val servers = parseMcpServersFromJson(
            """
            {
              "mcpServers": {
                "broken": {
                  "url": "https://broken.example/mcp",
                  "headers": []
                },
                "docs": {
                  "url": "https://example.com/mcp"
                }
              }
            }
            """.trimIndent()
        )

        assertEquals(1, servers.size)
        assertEquals("docs", servers.single().commonOptions.name)
    }

    private val McpServerConfig.transportType: String
        get() = when (this) {
            is McpServerConfig.SseTransportServer -> "sse"
            is McpServerConfig.StreamableHTTPServer -> "streamable_http"
        }
}
