import Foundation

/// Plugin packages with controlled capabilities and pinned script assets.
extension IOSRecipeIntegrationTestCase {
    func pluginFiles(
        version: String,
        readPrefixes: [String] = ["/workspace/plugin-data"],
        backgroundAllowed: Bool = false
    ) throws -> [String: Data] {
        let first = try jsonData([
            "schema": "amber.recipe.v1",
            "name": "list_tools",
            "version": version,
            "description": "List tools.",
            "inputs": [:],
            "steps": [["id": "list", "tool": "tools_list", "arguments": [:]]],
            "outputs": ["count": "${step.list.output.total}"],
        ])
        let second = try jsonData([
            "schema": "amber.recipe.v1",
            "name": "count_tools",
            "version": version,
            "description": "Count tools.",
            "inputs": [:],
            "steps": [["id": "list", "tool": "tools_list", "arguments": [:]]],
            "outputs": ["count": "${step.list.output.total}"],
        ])
        let plugin = try jsonData([
            "schema": "amber.plugin.v1",
            "id": "workspace_kit",
            "name": "Workspace Kit",
            "version": version,
            "description": "Two safe catalog helpers.",
            "tools": [
                ["name": "list_tools", "recipe": "recipes/list.json"],
                ["name": "count_tools", "recipe": "recipes/count.json"],
            ],
            "capabilities": [
                "workspaceReadPrefixes": readPrefixes,
                "workspaceWritePrefixes": [],
                "networkDomains": [],
                "webMountActions": [],
            ],
            "backgroundAllowed": backgroundAllowed,
        ])
        return [
            "plugin.json": plugin,
            "recipes/list.json": first,
            "recipes/count.json": second,
            "README.md": Data("# Workspace Kit\n".utf8),
        ]
    }

    func scriptPluginFiles(
        includeAsset: Bool = false,
        backgroundAllowed: Bool = false
    ) throws -> [String: Data] {
        let plugin = try jsonData([
            "schema": "amber.plugin.v1",
            "id": "script_kit",
            "name": "Script Kit",
            "version": "1.0.0",
            "description": "A restricted JavaScript helper.",
            "tools": [[
                "name": "greet",
                "description": "Build a greeting.",
                "script": "scripts/greet.js",
                "host_tools": [],
                "inputs": ["name": "string"],
                "output": "object",
                "timeout_ms": 2_000,
                "max_output_chars": 4_000,
            ]],
            "capabilities": [
                "workspaceReadPrefixes": [],
                "workspaceWritePrefixes": [],
                "networkDomains": [],
                "webMountActions": [],
            ],
            "backgroundAllowed": backgroundAllowed,
        ])
        var files: [String: Data] = [
            "plugin.json": plugin,
            "scripts/greet.js": Data(#"return { greeting: "hi " + input.name, dynamic: typeof eval };"#.utf8),
            "README.md": Data("# Script Kit\n".utf8),
        ]
        if includeAsset { files["assets/note.txt"] = Data("signed".utf8) }
        return files
    }

    func sideEffectScriptPluginFiles() throws -> [String: Data] {
        [
            "plugin.json": try jsonData([
                "schema": "amber.plugin.v1",
                "id": "writer_kit",
                "name": "Writer Kit",
                "version": "1.0.0",
                "description": "A scoped writer.",
                "tools": [[
                    "name": "write_note",
                    "script": "scripts/write.js",
                    "host_tools": ["workspace_file_write"],
                    "inputs": ["text": "string"],
                    "output": "object",
                ]],
                "capabilities": [
                    "workspaceReadPrefixes": [],
                    "workspaceWritePrefixes": ["/workspace/plugin-data"],
                    "networkDomains": [],
                    "webMountActions": [],
                ],
                "backgroundAllowed": false,
            ]),
            "scripts/write.js": Data(#"return tools.workspace_file_write({path: "/workspace/plugin-data/note.txt", content: input.text});"#.utf8),
        ]
    }

}
