package desktop

import app.amber.ai.core.InputSchema
import app.amber.ai.core.Tool
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement

@Serializable
private data class DesktopToolDeclaration(
    val name: String,
    val description: String,
    val parameters: JsonObject,
    val needsApproval: Boolean = false,
)

private val declarationJson = Json { ignoreUnknownKeys = true }

internal fun desktopDeclarations(json: String): List<Tool> {
    val declarations = declarationJson.decodeFromString<List<DesktopToolDeclaration>>(json)
    require(declarations.all { it.name.isNotBlank() }) { "Tool names must not be empty" }
    require(declarations.map { it.name }.distinct().size == declarations.size) { "Tool names must be unique" }
    return declarations.map { declaration ->
        val schema = declarationJson.decodeFromJsonElement<InputSchema>(declaration.parameters)
        Tool(name = declaration.name, description = declaration.description, parameters = { schema },
            needsApproval = declaration.needsApproval, allowsAutoApproval = !declaration.needsApproval,
            execute = { error("Desktop tools must be executed by their native host") })
    }
}
