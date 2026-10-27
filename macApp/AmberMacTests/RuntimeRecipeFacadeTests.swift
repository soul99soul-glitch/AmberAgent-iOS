import XCTest
@testable import AmberMac

@MainActor final class RuntimeRecipeFacadeTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
    }
    private final class Trace { var owners: [UUID] = [] }
    private func setup(directory: URL, delay: Bool = false) throws -> (DesktopWorkspace, Trace, UUID, UUID) {
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
        return (workspace, trace, first.id, second.id)
    }

    func testRecipeKeepsCapturedOwnerAfterSelectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (workspace, trace, first, second) = try setup(directory: directory)
        let id = try XCTUnwrap(workspace.runRecipe(name: "owner_check", inputs: [:]))
        workspace.select(second)
        await workspace.recipes.waitUntilFinished(id)
        XCTAssertEqual(trace.owners, [first])
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.conversationID, first)
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.status, .completed)
        XCTAssertEqual(workspace.selectedID, second)
    }

    func testDeletingOwnerCancelsOnlyItsAcceptedRecipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (workspace, trace, first, second) = try setup(directory: directory, delay: true)
        let id = try XCTUnwrap(workspace.runRecipe(name: "owner_check", inputs: [:]))
        while trace.owners.isEmpty { await Task.yield() }
        workspace.delete(first)
        await workspace.recipes.waitUntilFinished(id)
        _ = await workspace.flush()
        XCTAssertEqual(workspace.agentTasks.records.first { $0.id == id }?.status, .cancelled)
        XCTAssertEqual(workspace.selectedID, second)
        XCTAssertFalse(workspace.summaries.contains { $0.id == first })
    }
}
