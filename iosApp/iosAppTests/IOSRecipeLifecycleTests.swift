import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Recipe lifecycle, validation, and tool declarations.
@MainActor
final class IOSRecipeLifecycleTests: IOSRecipeIntegrationTestCase {
    func testPrimitiveCatalogMatchesExecutableRecipeRoutes() {
        for supported in [
            "workspace_file_read",
            "tools_list",
            "skill_validate",
            "ios_shell_execute",
            "mcp_call",
            "provider_config_status",
            "theme_pack_status",
        ] {
            XCTAssertNotNil(
                IOSDynamicToolRegistry.primitiveCatalogEntry(for: supported),
                "\(supported) has a real recipe adapter"
            )
        }

        for rejected in [
            "skill_import",
            "provider_config_apply",
            "theme_pack_import",
            "recipe_import",
            "generate_image",
            "mcp__unknown__missing",
            "wm_eval",
            "wm_site_memory",
        ] {
            XCTAssertNil(
                IOSDynamicToolRegistry.primitiveCatalogEntry(for: rejected),
                "\(rejected) must fail validation instead of changing semantics at runtime"
            )
        }
    }

    func testMalformedRecipeReportsFieldInValidationAndImportWithoutWrites() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let workspace = makeWorkspaceStore(root: root)
        let service = IOSRecipeToolService(
            workspaceStore: workspace,
            recipeStore: store,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            refreshRegistry: { nil }
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: listingRecipeJSON(version: "1.0.0")
        ) as? [String: Any])
        object["steps"] = [["id": "list", "tool": "tools_list"]]
        let missingArguments = try JSONSerialization.data(withJSONObject: object)
        object["steps"] = [["id": "list", "tool": "tools_list", "arguments": [:]]]
        object["inputs"] = ["query": ["type": "string"]]
        let wrongInputType = try JSONSerialization.data(withJSONObject: object)
        let before = directorySnapshot(store.recipesDirectory)
        for (data, path) in [(missingArguments, "steps[0].arguments"), (wrongInputType, "inputs.query")] {
            try await seedWorkspaceRecipe(
                workspace: workspace, json: data,
                workspacePath: "/workspace/recipes/invalid/recipe.json"
            )
            let args = #"{"workspace_path":"/workspace/recipes/invalid/recipe.json"}"#
            let result = await service.execute(toolName: "recipe_validate", arguments: args)
            let parsed = try XCTUnwrap(parse(result))
            XCTAssertEqual(parsed["ok"] as? Bool, false, result)
            XCTAssertEqual(parsed["path"] as? String, path, result)
            XCTAssertEqual(parsed["code"] as? String, "invalidManifestJSON", result)
            XCTAssertThrowsError(try service.prepareRecipeImport(arguments: args)) { error in
                XCTAssertEqual((error as? IOSRecipeValidationIssue)?.path, path)
                XCTAssertTrue(error.localizedDescription.contains(path))
            }
            XCTAssertEqual(IOSRecipeValidator.validate(
                data: data, catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
            ).issues.first?.path, path)
        }
        XCTAssertEqual(directorySnapshot(store.recipesDirectory), before)
    }

    func testRecipeLifecycleSeparatesInstalledPackagesFromEnabledCatalog() async throws {
        let root = tempRoot()
        let store = makeStore(root: root)
        let registry = makeRegistry(store: store)
        let hash = try apply(store: store, json: try listingRecipeJSON(version: "1.0.0"))

        XCTAssertEqual(store.listInstalledRecipes().map(\.package.name), ["catalog_probe"])
        XCTAssertTrue(store.isRecipeEnabled(name: "catalog_probe"))
        let enabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(enabledSnapshot.recipeTools.map(\.toolId), ["recipe__catalog_probe"])

        let disabled = try store.setRecipeEnabled(
            name: "catalog_probe",
            enabled: false,
            expectedHash: hash
        )
        XCTAssertTrue(disabled.changed)
        XCTAssertEqual(store.listInstalledRecipes().map(\.isEnabled), [false])
        let disabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(disabledSnapshot.recipeTools.isEmpty)
        XCTAssertGreaterThan(disabledSnapshot.revision, enabledSnapshot.revision)

        XCTAssertThrowsError(try store.setRecipeEnabled(
            name: "catalog_probe",
            enabled: true,
            expectedHash: "stale"
        ))

        _ = try store.setRecipeEnabled(name: "catalog_probe", enabled: true, expectedHash: hash)
        let reenabledSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertEqual(reenabledSnapshot.recipeTools.map(\.toolId), ["recipe__catalog_probe"])

        _ = try store.deleteRecipe(name: "catalog_probe", expectedHash: hash)
        XCTAssertTrue(store.listInstalledRecipes().isEmpty)
        let deletedSnapshot = try unwrapSnapshot(await registry.refresh())
        XCTAssertTrue(deletedSnapshot.recipeTools.isEmpty)
    }

    func testRecipeLifecycleToolsAreDeclaredWithExpectedRisk() {
        XCTAssertEqual(IOSRecipeToolCatalog.toolNames, [
            "recipes_list", "recipe_validate", "recipe_import",
            "recipe_enable", "recipe_disable", "recipe_delete",
        ])
        for name in IOSRecipeToolCatalog.toolNames {
            XCTAssertNotNil(ToolKt.iosToolDeclaration(name: name), "missing declaration for \(name)")
        }
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipes_list", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipe_validate", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("recipe_delete", input: "{}"), .sideEffect)
    }

}
