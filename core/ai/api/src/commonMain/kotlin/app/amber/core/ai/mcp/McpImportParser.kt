package app.amber.core.ai.mcp

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class McpImportParseError(
    val serverName: String,
    val code: String,
    val message: String,
)

data class McpImportParseResult(
    val servers: List<McpServerConfig>,
    val errors: List<McpImportParseError>,
)

fun parseMcpServersFromJson(json: String): List<McpServerConfig> {
    return parseMcpServersWithDiagnostics(json).servers
}

fun parseMcpServersWithDiagnostics(json: String): McpImportParseResult {
    val rootElement = runCatching { Json.parseToJsonElement(json) }.getOrNull()
        ?: return documentError("invalid_json", "MCP JSON is invalid")
    val root = rootElement as? JsonObject
        ?: return documentError("invalid_json", "MCP JSON is invalid")
    val mcpServersElement = root["mcpServers"]
        ?: return documentError("missing_mcp_servers", "MCP JSON is missing mcpServers")
    val mcpServers = mcpServersElement as? JsonObject
        ?: return documentError("invalid_mcp_servers", "mcpServers must be an object")

    val servers = mutableListOf<McpServerConfig>()
    val errors = mutableListOf<McpImportParseError>()
    for ((name, element) in mcpServers) {
        try {
            val obj = element as? JsonObject
                ?: throw McpImportParseFailure("invalid_server", "MCP server must be an object")
            val transport = obj.resolveTransport()
            val url = (obj["url"] as? JsonPrimitive)?.contentOrNull
                ?.takeIf { it.isNotBlank() }
                ?: throw McpImportParseFailure("missing_url", "MCP server URL is missing")
            val headers = obj.parseHeaders()
            val commonOptions = McpCommonOptions(name = name, headers = headers)
            servers += when (transport) {
                McpImportTransport.Sse -> McpServerConfig.SseTransportServer(commonOptions = commonOptions, url = url)
                McpImportTransport.StreamableHttp -> McpServerConfig.StreamableHTTPServer(commonOptions = commonOptions, url = url)
            }
        } catch (failure: McpImportParseFailure) {
            errors += McpImportParseError(name, failure.code, failure.message.orEmpty())
        }
    }
    return McpImportParseResult(servers = servers, errors = errors)
}

private fun documentError(code: String, message: String): McpImportParseResult {
    return McpImportParseResult(
        servers = emptyList(),
        errors = listOf(McpImportParseError(serverName = "", code = code, message = message)),
    )
}

private class McpImportParseFailure(
    val code: String,
    message: String,
) : IllegalArgumentException(message)

private enum class McpImportTransport {
    Sse,
    StreamableHttp,
}

private fun JsonObject.resolveTransport(): McpImportTransport {
    val type = parseTransportField("type")
    val transport = parseTransportField("transport")
    if (type != null && transport != null && type != transport) {
        throw McpImportParseFailure(
            code = "conflicting_transport",
            message = "MCP server type and transport disagree",
        )
    }
    return type ?: transport ?: McpImportTransport.StreamableHttp
}

private fun JsonObject.parseTransportField(field: String): McpImportTransport? {
    val value = this[field] ?: return null
    val rawValue = (value as? JsonPrimitive)?.contentOrNull
        ?: throw McpImportParseFailure(
            code = "unsupported_transport",
            message = "MCP server $field must be a non-empty string",
        )
    return when (rawValue.trim().lowercase()) {
        "sse" -> McpImportTransport.Sse
        "streamable_http", "streamablehttp", "streamable-http" -> McpImportTransport.StreamableHttp
        else -> throw McpImportParseFailure(
            code = "unsupported_transport",
            message = "Unsupported MCP server $field: $rawValue",
        )
    }
}

private fun JsonObject.parseHeaders(): List<Pair<String, String>> {
    val value = this["headers"] ?: return emptyList()
    val headers = value as? JsonObject
        ?: throw McpImportParseFailure("invalid_headers", "MCP server headers must be an object")
    return headers.entries.map { (key, headerValue) ->
        val text = (headerValue as? JsonPrimitive)?.contentOrNull
            ?: throw McpImportParseFailure("invalid_headers", "MCP server header $key must be a string")
        key to text
    }
}
