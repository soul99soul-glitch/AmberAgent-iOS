import XCTest
@testable import AmberMac

@MainActor final class RuntimeRecipeFacadeTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
    }
    private final class Trace { var owners: [UUID] = [] }
    private struct Fixture {
        let workspace: DesktopWorkspace
        let trace: Trace
        let first: UUID
        let second: UUID
    }
    private func setup(directory: URL, delay: Bool = false) throws -> Fixture {
        let defaults = UserDefaults(suiteName: "amber.recipe-facade.\(UUID().uuidString)")!
        let tasks = DesktopAgentTasks(defaults: defaults)
        let manifest = DesktopRecipeManifest(name: "owner_check", version: "1", description: "record owner", inputs: [:],
            steps: [DesktopRecipeStep(id: "check", tool: "record", arguments: [:])],
            outputs: ["owner": .string("${step.check.output.owner}")])
        let source = directory.appendingPathComponent("recipe.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.canonicalJSON().utf8).write(to: source)
        let store = DesktopRecipeStore(directory: directory.appendingPathComponent("installed"), registeredTools: ["record"])
        try store.importRecipe(from: source)
        try store.setEnabled("owner_check", enabled: true)
        let trace = Trace()
        let recipes = DesktopRecipeRuns(store: store, tasks: tasks) { _, owner, _, _ in
            trace.owners.append(owner)
            if delay { try await Task.sleep(for: .seconds(10)) }
            return "{\"owner\":\"\(owner.uuidString)\"}"
        }
        let first = DesktopConversation(title: "first"), second = DesktopConversation(title: "second")
        let workspace = DesktopWorkspace(settings: DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials()),
            storage: DesktopMemoryConversationStorage([first, second]), provider: Provider(), initialConversations: [first, second],
            agentTasks: tasks, recipes: recipes)
        // `DesktopWorkspace` reconciles registered recipe tools from its plugin store at init, so re-declare
        // this store's own tool after construction instead of relying on the plugin registry.
        recipes.store.registeredTools = ["record"]
        return Fixture(workspace: workspace, trace: trace, first: first.id, second: second.id)
    }

    func testRecipeKeepsCapturedOwnerAfterSelectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try setup(directory: directory)
        let workspace = fixture.workspace
        let id = try XCTUnwrap(workspace.runRecipe(name: "owner_check", inputs: [:]))
        workspace.select(fixture.second)
        await workspace.recipes.waitUntilFinished(id)
        XCTAssertEqual(fixture.trace.owners, [fixture.first], "recipe error: \(workspace.recipes.errorMessage ?? "none") task: \(workspace.agentTasks.records.first { $0.id == id }?.error ?? "none")")
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.conversationID, fixture.first)
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.status, .completed)
        XCTAssertEqual(workspace.selectedID, fixture.second)
    }

    func testDeletingOwnerCancelsOnlyItsAcceptedRecipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try setup(directory: directory, delay: true)
        let workspace = fixture.workspace
        let id = try XCTUnwrap(workspace.runRecipe(name: "owner_check", inputs: [:]))
        // The run starts as a main-actor task: spin-waiting with `Task.yield()` here starves that task, so
        // give the executor a real suspension and fail loudly if the tool is never reached.
        let deadline = Date().addingTimeInterval(2)
        while fixture.trace.owners.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.trace.owners, [fixture.first],
            "the recipe run must reach its tool before the owner is deleted; error: \(workspace.recipes.errorMessage ?? "none") task: \(workspace.agentTasks.records.first { $0.id == id }?.error ?? "none")")
        workspace.delete(fixture.first)
        await workspace.recipes.waitUntilFinished(id)
        _ = await workspace.flush()
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.status, .cancelled)
        XCTAssertEqual(workspace.selectedID, fixture.second)
        XCTAssertFalse(workspace.summaries.contains { $0.id == fixture.first })
    }
}
