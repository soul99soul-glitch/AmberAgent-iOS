import SwiftUI
import UIKit
@preconcurrency import Shared

enum ChatToolUndoRequest: Equatable {
    case workspace(path: String, snapshotID: String)
    case memory(id: Int, token: String)
    case wiki(path: String, previousRevision: String, currentRevision: String)
    case eventKit(toolName: String, identifier: String, runID: String)

    var buttonTitle: String {
        switch self {
        case .eventKit: "预填撤回请求（发送后需审批）"
        default: "撤销这次修改"
        }
    }

    @MainActor
    static func from(tool: UIMessagePart.Tool) -> Self? {
        guard let result = ChatToolStepModel.firstJSONObject(in: tool.output), result["ok"] as? Bool == true else { return nil }
        if ["workspace_file_write", "workspace_file_edit", "workspace_file_move"].contains(tool.toolName),
           let path = result["path"] as? String, let id = result["undo_snapshot_id"] as? String {
            return .workspace(path: path, snapshotID: id)
        }
        if tool.toolName == "memory_tool" {
            if let token = result["undo_token"] as? String,
               let id = result["id"] as? Int ?? (result["memory"] as? [String: Any])?["id"] as? Int {
                return .memory(id: id, token: token)
            }
            if let data = tool.input.data(using: .utf8),
               let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               input["action"] as? String == "wiki_edit",
               let previous = input["expected_revision"] as? String, !previous.isEmpty,
               let current = result["revision"] as? String, let path = result["path"] as? String {
                return .wiki(path: path, previousRevision: previous, currentRevision: current)
            }
        }
        if let runID = result["created_run_id"] as? String, !runID.isEmpty {
            if tool.toolName == IOSAppleAgentToolCatalog.calendarEventCreate, let id = result["event_id"] as? String {
                return .eventKit(toolName: IOSAppleAgentToolCatalog.calendarEventDelete, identifier: id, runID: runID)
            }
            if tool.toolName == IOSAppleAgentToolCatalog.reminderCreate, let id = result["reminder_id"] as? String {
                return .eventKit(toolName: IOSAppleAgentToolCatalog.reminderDelete, identifier: id, runID: runID)
            }
        }
        return nil
    }

    var eventKitPrefill: String? {
        guard case let .eventKit(name, identifier, _) = self else { return nil }
        let key = name == IOSAppleAgentToolCatalog.calendarEventDelete ? "event_id" : "reminder_id"
        guard let data = try? JSONSerialization.data(withJSONObject: [key: identifier], options: [.sortedKeys]),
              let input = String(data: data, encoding: .utf8) else { return nil }
        return "请撤回本轮新建项，仅调用一次 \(name)，参数：\(input)。执行前请提交审批，不要删除其他条目。"
    }
}

/// A stable reference keeps the owner current across retained tool detail sheets.
@MainActor
final class ChatToolUndoHandler {
    weak var viewModel: ChatViewModel?

    func request(for tool: UIMessagePart.Tool) -> ChatToolUndoRequest? {
        guard let model = viewModel, !model.isGenerationActive, !model.hasPendingUserGate,
              let request = ChatToolUndoRequest.from(tool: tool) else { return nil }
        switch request {
        case .workspace:
            guard model.sharedSettings.isCapabilityGateEnabled(.workspace) else { return nil }
        case let .memory(id, token):
            guard AmberHubStore.shared.allowsGlobalMemory(conversationId: model.currentConversationId?.toHexDashString()),
                  let entry = IOSMemoryRecordUndoStore.shared.entry(for: id), entry.token == token,
                  !ChatMemoryContextBuilder.recordsForPrompt(records: [entry.previousRecord], runtime: model.sharedSettings.agentRuntime).isEmpty else { return nil }
        case .wiki:
            guard AmberHubStore.shared.allowsGlobalMemory(conversationId: model.currentConversationId?.toHexDashString()),
                  model.sharedSettings.agentRuntime.enableLongTermMemory else { return nil }
        case let .eventKit(toolName, id, runID):
            // Only the latest user turn can offer a withdrawal. The tracker also
            // binds the exact created identifier to its original run.
            let messages = model.currentRun.state.untrackedMessages
            guard let userIndex = messages.lastIndex(where: { $0.role == .user }),
                  messages.suffix(from: userIndex).flatMap(\.parts).contains(where: { ($0 as? UIMessagePart.Tool)?.toolCallId == tool.toolCallId }),
                  IOSEventKitTurnCreationTracker.shared.createdItems(forRunId: runID).contains(where: {
                      $0.identifier == id && $0.kind == (toolName == IOSAppleAgentToolCatalog.calendarEventDelete ? .event : .reminder)
                  }) else { return nil }
        }
        return request
    }

    func perform(tool: UIMessagePart.Tool) -> String {
        guard UIApplication.shared.applicationState == .active,
              let model = viewModel, let request = request(for: tool) else { return "当前状态已变化，无法撤销。请重新查看目标现状。" }
        let result: [String: Any]
        switch request {
        case let .workspace(path, id):
            guard let policy = model.localToolExecutor?.permissionPolicy(capabilityId: "ios.workspace.file_write"),
                  policy != .disabled else { return "Workspace 写入权限已关闭。" }
            result = model.workspaceStore.undoLastChange(forPath: path, expectedSnapshotID: id)
        case let .memory(id, token):
            guard model.localToolExecutor?.memoryToolWritePolicy(input: #"{"action":"edit"}"#, isUserInitiated: true) == .allow else { return "记忆写入权限已关闭。" }
            result = IOSMemoryToolExecutor.revertLastRecordMutation(memoryId: id, expectedToken: token)
        case let .wiki(path, previous, current):
            guard model.localToolExecutor?.memoryToolWritePolicy(input: #"{"action":"wiki_revert"}"#, isUserInitiated: true) == .allow else { return "记忆写入权限已关闭。" }
            result = IOSMemoryWikiTool.execute(args: ["action": "wiki_revert", "path": path, "revision_id": previous,
                                                     "expected_revision": current, "reason": "用户撤销本次编辑"],
                                               runtime: model.sharedSettings.agentRuntime, persistence: .shared, writePolicy: .allow)
        case .eventKit:
            guard let prompt = request.eventKitPrefill else { return "无法生成撤回请求。" }
            let draft = model.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.contains(prompt) { model.inputText = draft.isEmpty ? prompt : draft + "\n" + prompt }
            return "已预填撤回请求。请发送后检查并批准删除操作；当前尚未撤回。"
        }
        return result["ok"] as? Bool == true ? "已撤销这次修改。" : (result["error"] as? String ?? "撤销失败，请检查目标现状。")
    }
}

private struct ChatToolUndoHandlerKey: EnvironmentKey {
    static let defaultValue: ChatToolUndoHandler? = nil
}

extension EnvironmentValues {
    var chatToolUndoHandler: ChatToolUndoHandler? {
        get { self[ChatToolUndoHandlerKey.self] }
        set { self[ChatToolUndoHandlerKey.self] = newValue }
    }
}
