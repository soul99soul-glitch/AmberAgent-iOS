import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatToolUndoRoutingTests: XCTestCase {
    private func tool(_ name: String, input: String = "{}", output: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(toolCallId: UUID().uuidString, toolName: name, input: input,
            output: [UIMessagePart.Text(text: output, metadata: nil)], approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil, metadata: nil)
    }

    func testWorkspaceReceiptBindsUndoToExactMutationAndAuditsStaleAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSWorkspaceStore(baseDirectory: root)
        let first = await store.executeTool(toolName: "workspace_file_write", input: #"{"path":"plan.md","content":"first"}"#)
        let firstTool = tool("workspace_file_write", output: first)
        guard case let .workspace(path, firstID) = try XCTUnwrap(ChatToolUndoRequest.from(tool: firstTool)) else {
            return XCTFail("successful write must carry an undo receipt")
        }
        let second = await store.executeTool(toolName: "workspace_file_edit", input: #"{"path":"plan.md","find":"first","replace":"second"}"#)
        let secondRequest = try XCTUnwrap(ChatToolUndoRequest.from(tool: tool("workspace_file_edit", output: second)))
        guard case let .workspace(_, secondID) = secondRequest else { return XCTFail("edit receipt missing") }
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(store.undoLastChange(forPath: path, expectedSnapshotID: firstID)["conflict"] as? Bool, true)
        XCTAssertEqual(store.undoAuditEntries().last?.action, "undo_conflict")
        XCTAssertEqual(store.undoLastChange(forPath: path, expectedSnapshotID: secondID)["ok"] as? Bool, true)
        let record = try XCTUnwrap(store.fileRecord(idOrPath: path))
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: record), encoding: .utf8), "first")
        XCTAssertEqual(store.undoAuditEntries().last?.action, "undone")
    }

    func testEventKitUndoOnlyBuildsOneApprovedDeleteRequestForCreatedItems() throws {
        let created = tool(IOSAppleAgentToolCatalog.calendarEventCreate,
            output: #"{"ok":true,"event_id":"event-1","created_run_id":"run-1"}"#)
        let request = try XCTUnwrap(ChatToolUndoRequest.from(tool: created))
        XCTAssertEqual(request, .eventKit(toolName: IOSAppleAgentToolCatalog.calendarEventDelete, identifier: "event-1", runID: "run-1"))
        XCTAssertTrue(request.eventKitPrefill?.contains(#"calendar_event_delete，参数：{"event_id":"event-1"}"#) == true)
        XCTAssertTrue(request.eventKitPrefill?.contains("提交审批") == true)
        XCTAssertTrue(IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(IOSAppleAgentToolCatalog.calendarEventDelete))
        XCTAssertTrue(IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(IOSAppleAgentToolCatalog.reminderDelete))
        XCTAssertNil(ChatToolUndoRequest.from(tool: tool(IOSAppleAgentToolCatalog.calendarEventUpdate, output: #"{"ok":true,"event_id":"historical","created_run_id":"run-1"}"#)))
        XCTAssertNil(ChatToolUndoRequest.from(tool: tool(IOSAppleAgentToolCatalog.calendarEventCreate, output: #"{"ok":false,"event_id":"failed","created_run_id":"run-1"}"#)))
        XCTAssertNil(ChatToolUndoRequest.from(tool: tool("remote_shell_execute", output: #"{"ok":true}"#)))
    }

    func testEventKitDetailActionRequiresCurrentTurnAndExactRunOwner() throws {
        let suite = "ToolUndoOwner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); IOSEventKitTurnCreationTracker.shared.reset() }
        let model = ChatViewModel(settingsStore: SettingsStore(userDefaults: defaults, storageKey: "undo-owner"), autoGenerateResponses: false)
        let handler = ChatToolUndoHandler()
        handler.viewModel = model
        let created = tool(IOSAppleAgentToolCatalog.reminderCreate,
            output: #"{"ok":true,"reminder_id":"r-1","created_run_id":"run-1"}"#)
        let seed = UIMessage.companion.assistant(prompt: "")
        let assistant = seed.doCopy(id: seed.id, role: seed.role, parts: [created], annotations: seed.annotations,
            createdAt: seed.createdAt, finishedAt: seed.finishedAt, modelId: seed.modelId, usage: seed.usage, translation: seed.translation)
        model.currentRun.state.messages = [UIMessage.companion.user(prompt: "创建提醒"), assistant]
        XCTAssertNil(handler.request(for: created), "A matching output alone cannot claim run ownership")
        IOSEventKitTurnCreationTracker.shared.recordCreated(runId: "other-run", kind: .reminder, identifier: "r-1", title: "other")
        XCTAssertNil(handler.request(for: created))
        IOSEventKitTurnCreationTracker.shared.recordCreated(runId: "run-1", kind: .reminder, identifier: "r-1", title: "current")
        XCTAssertNotNil(handler.request(for: created))
        model.currentRun.state.messages.append(UIMessage.companion.user(prompt: "开始下一轮"))
        XCTAssertNil(handler.request(for: created), "A prior turn cannot expose withdrawal")
    }

    func testWikiUndoCarriesPreviousAndCurrentRevisionAndLegacyToolsOfferNoUndo() throws {
        let edited = tool("memory_tool", input: #"{"action":"wiki_edit","path":"notes/a.md","expected_revision":"before","content":"new"}"#,
            output: #"{"ok":true,"path":"notes/a.md","revision":"after"}"#)
        XCTAssertEqual(ChatToolUndoRequest.from(tool: edited), .wiki(path: "notes/a.md", previousRevision: "before", currentRevision: "after"))
        XCTAssertNil(ChatToolUndoRequest.from(tool: tool("workspace_file_write", output: #"{"ok":true,"path":"a.md"}"#)))
        XCTAssertNil(ChatToolUndoRequest.from(tool: tool("memory_tool", output: #"{"ok":true,"action":"create","memory":{"id":1}}"#)))
    }
}
