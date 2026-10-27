import XCTest
@testable import AmberMac

@MainActor final class RuntimeCollaborationSaveTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration(); runs.append(run); return run
        }
    }
    private final class Storage: DesktopConversationStorage {
        var values: [DesktopConversation]
        var failSave = false
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            if failSave { throw DesktopRuntimeError.message("disk failure") }
            values.removeAll { $0.id == value.id }; values.append(value); return value
        }
        func delete(_ id: UUID) async throws { values.removeAll { $0.id == id } }
    }
    private func setup(_ values: [DesktopConversation]) throws -> (DesktopWorkspace, Provider, Storage) {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.collab-save.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        var configuration = settings.selectedProvider!
        configuration.modelID = "test-model"
        try settings.saveProvider(configuration, apiKey: "test-key")
        let provider = Provider(), storage = Storage(values)
        return (DesktopWorkspace(settings: settings, storage: storage, provider: provider, initialConversations: values), provider, storage)
    }
    private func finish(_ workspace: DesktopWorkspace, provider: Provider, owner: UUID) async throws -> UUID {
        let id = try workspace.collaborations.startSubagents(parentConversationID: owner, objective: "write an artifact",
            members: [DesktopCollaborationMember(name: "Writer", rolePrompt: "write")])
        while provider.runs.isEmpty { await Task.yield() }
        provider.runs[0].yield(.snapshot(text: "actual collaboration output", reasoning: ""))
        provider.runs[0].yield(.complete)
        _ = await workspace.collaborations.waitUntilFinished(id)
        return id
    }

    func testSaveUsesParentOwnerAndPublishesOnceAfterDurableWrite() async throws {
        let original = DesktopConversation(title: "owner"), other = DesktopConversation(title: "other")
        let (workspace, provider, storage) = try setup([original, other])
        let id = try await finish(workspace, provider: provider, owner: original.id)
        workspace.select(other.id)
        await workspace.saveCollaborationResult(runID: id)?.value
        XCTAssertEqual(workspace.selectedID, other.id)
        XCTAssertTrue(workspace.selectedConversation?.messages.isEmpty == true)
        let saved = try XCTUnwrap(storage.values.first { $0.id == original.id })
        XCTAssertEqual(saved.messages.last?.id, id)
        XCTAssertTrue(saved.messages.last?.text.contains("actual collaboration output") == true)
        let path = "outputs/collaboration-" + id.uuidString.lowercased() + ".md"
        let file = try await workspace.files.read(conversationID: original.id, path: path)
        XCTAssertTrue(String(decoding: file, as: UTF8.self).contains("actual collaboration output"))
        await workspace.saveCollaborationResult(runID: id)?.value
        XCTAssertEqual(workspace.conversations.first { $0.id == original.id }?.messages.count, 1)
        XCTAssertTrue(workspace.savedCollaborationRuns.contains(id))
    }

    func testComposerCouncilModePlansSeatsAndWritesResultBackToConversation() async throws {
        let original = DesktopConversation(title: "owner")
        let (workspace, provider, storage) = try setup([original])
        workspace.select(original.id)
        workspace.composerMode = .council
        workspace.draft = "要不要把 stdio 改成登录 shell"
        workspace.sendCollaboration()
        XCTAssertEqual(workspace.draft, "")
        let runID = try XCTUnwrap(workspace.composerRunID)
        let run = try XCTUnwrap(workspace.collaborations.runs.first { $0.id == runID })
        XCTAssertTrue(run.isCouncil)
        XCTAssertEqual(run.objective, "要不要把 stdio 改成登录 shell")
        // Host plans two seats, then every later call (seat turns, commentary, synthesis) answers.
        while provider.runs.isEmpty { await Task.yield() }
        provider.runs[0].yield(.snapshot(text: #"[{"name":"甲","rolePrompt":"支持"},{"name":"乙","rolePrompt":"反对"}]"#, reasoning: ""))
        provider.runs[0].yield(.complete)
        var answered = 1
        while !(workspace.collaborations.runs.first { $0.id == runID }?.status.isTerminal ?? true) {
            if provider.runs.count > answered {
                provider.runs[answered].yield(.snapshot(text: "观点 \(answered)", reasoning: ""))
                provider.runs[answered].yield(.complete)
                answered += 1
            }
            await Task.yield()
        }
        for _ in 0..<200 where !(workspace.savedCollaborationRuns.contains(runID)) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(workspace.composerRunID)
        let saved = try XCTUnwrap(storage.values.first { $0.id == original.id })
        XCTAssertEqual(saved.messages.last?.id, runID)
        XCTAssertTrue(saved.messages.last?.text.contains("议会协作结果") == true)
    }

    func testSubagentSwitchExposesDispatchToolOnlyWhenOn() {
        XCTAssertTrue(DesktopToolRegistry.collaborationDeclarations(subagents: true).contains { $0.name == "subagent_dispatch" })
        XCTAssertFalse(DesktopToolRegistry.collaborationDeclarations(subagents: false).contains { $0.name == "subagent_dispatch" })
        XCTAssertTrue(DesktopToolRegistry.collaborationDeclarations(subagents: false).contains { $0.name == "model_council_run" })
        let context = DesktopRunContext(conversationID: UUID(), toolsEnabled: false, subagentsEnabled: true)
        XCTAssertFalse(context.toolsEnabled, "the context keeps the real ordinary-tools switch")
        XCTAssertTrue(context.engineEnabled, "sub-agents still need the tool engine")
    }

    func testAgentDeclarationsStayWithinEachCapabilitySwitch() {
        let base = Set(DesktopToolRegistry.declarations.map(\.name))
        let knowledge = Set(DesktopToolRegistry.knowledgeDeclarations.map(\.name))
        let mcp = Set(DesktopMCPManager.declarations.map(\.name))
        let council = Set(["list_agents", "interrupt_agent", "model_council_run"])
        let subagents = Set(["subagent_dispatch", "list_agents", "interrupt_agent"])

        let none = Set(DesktopToolRegistry.agentDeclarations(toolsEnabled: false, subagentsEnabled: false).map(\.name))
        let toolsOnly = Set(DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: false).map(\.name))
        let subagentsOnly = Set(DesktopToolRegistry.agentDeclarations(toolsEnabled: false, subagentsEnabled: true).map(\.name))
        let both = Set(DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: true).map(\.name))

        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(toolsOnly, base.union(knowledge).union(mcp).union(council))
        XCTAssertEqual(subagentsOnly, subagents)
        XCTAssertEqual(both, base.union(knowledge).union(mcp).union(council).union(["subagent_dispatch"]))
        XCTAssertFalse(subagentsOnly.contains("model_council_run"), "sub-agent-only mode must not grant council")
        XCTAssertFalse(subagentsOnly.contains("terminal_exec"), "sub-agent-only mode must not grant ordinary tools")
        XCTAssertFalse(subagentsOnly.contains("mcp_call_tool"), "sub-agent-only mode must not grant MCP")
    }

    func testFailedMessageSaveKeepsArtifactAndDoesNotPublishSuccess() async throws {
        let original = DesktopConversation(title: "owner"), other = DesktopConversation(title: "other")
        let (workspace, provider, storage) = try setup([original, other])
        let id = try await finish(workspace, provider: provider, owner: original.id)
        storage.failSave = true
        workspace.select(other.id)
        await workspace.saveCollaborationResult(runID: id)?.value
        XCTAssertFalse(workspace.savedCollaborationRuns.contains(id))
        XCTAssertNotNil(workspace.collaborationSaveErrors[id])
        XCTAssertTrue(workspace.conversations.first { $0.id == original.id }?.messages.isEmpty == true)
        XCTAssertTrue(storage.values.first { $0.id == original.id }?.messages.isEmpty == true)
        XCTAssertNil(workspace.errorMessage)
        workspace.select(original.id)
        XCTAssertNotNil(workspace.errorMessage)
        let entries = try await workspace.files.list(conversationID: original.id)
        XCTAssertEqual(entries.count, 1)
        storage.failSave = false
        await workspace.saveCollaborationResult(runID: id)?.value
        XCTAssertTrue(workspace.savedCollaborationRuns.contains(id))
        XCTAssertNil(workspace.collaborationSaveErrors[id])
        XCTAssertNil(workspace.errorMessage)
    }
}
