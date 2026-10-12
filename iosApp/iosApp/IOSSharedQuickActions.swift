import Foundation
@preconcurrency import Shared

enum IOSSharedQuickActionError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case emptyPrompt
    case promptTooLong
    case unsupportedPrompt
    case missingAction
    case missingInput
    case unresolvedInput
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "常用任务标题不能为空。"
        case .titleTooLong: "常用任务标题不能超过 40 个字符。"
        case .emptyPrompt: "常用任务内容不能为空。"
        case .promptTooLong: "常用任务内容不能超过 2000 个字符。"
        case .unsupportedPrompt: "请填写可直接交给 Amber 的任务内容。"
        case .missingAction: "这条常用任务已被删除，请重新选择。"
        case .missingInput: "这条常用任务需要输入，请填写后再运行。"
        case .unresolvedInput: "输入中不能包含 {输入}、{輸入} 或 {input} 占位符。"
        case .persistenceFailed(let message): message
        }
    }
}

@MainActor
extension IOSSharedSettingsStore {
    func savedQuickActions() -> [WatchQuickAction] {
        snapshot.quickMessages.compactMap { message in
            let title = message.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard WatchQuickAction.supports(prompt: prompt) else { return nil }
            let displayTitle = title.isEmpty
                ? String(localized: "未命名快捷消息", table: "AppIntents")
                : title
            return WatchQuickAction(id: message.id.toHexDashString(), title: displayTitle, prompt: prompt)
        }
    }

    @discardableResult
    func saveQuickAction(id: String? = nil, title: String, prompt: String) throws -> WatchQuickAction {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw IOSSharedQuickActionError.emptyTitle }
        guard title.count <= 40 else { throw IOSSharedQuickActionError.titleTooLong }
        let prompt = try validatedQuickActionPrompt(prompt)
        let actionID: String
        if let id {
            guard let existing = snapshot.quickMessages.first(where: {
                $0.id.toHexDashString().caseInsensitiveCompare(id) == .orderedSame
            }) else { throw IOSSharedQuickActionError.missingAction }
            actionID = existing.id.toHexDashString()
        } else {
            actionID = UUID().uuidString.lowercased()
        }
        try updateSavedQuickMessages { messages in
            let value: [String: Any] = ["id": actionID, "title": title, "content": prompt]
            if let index = messages.firstIndex(where: {
                ($0["id"] as? String)?.caseInsensitiveCompare(actionID) == .orderedSame
            }) {
                messages[index] = value
            } else {
                messages.append(value)
            }
        }
        return WatchQuickAction(id: actionID, title: title, prompt: prompt)
    }

    func deleteQuickAction(id: String) throws {
        guard snapshot.quickMessages.contains(where: {
            $0.id.toHexDashString().caseInsensitiveCompare(id) == .orderedSame
        }) else { throw IOSSharedQuickActionError.missingAction }
        try updateSavedQuickMessages { messages in
            messages.removeAll {
                ($0["id"] as? String)?.caseInsensitiveCompare(id) == .orderedSame
            }
        }
    }

    func resolvedQuickActionPrompt(id: String, input: String?) throws -> String {
        guard let action = savedQuickActions().first(where: {
            $0.id.caseInsensitiveCompare(id) == .orderedSame
        }) else { throw IOSSharedQuickActionError.missingAction }
        guard action.isTemplate else { return action.prompt }
        let input = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !input.isEmpty else { throw IOSSharedQuickActionError.missingInput }
        guard !WatchQuickAction.placeholders.contains(where: { input.contains($0) }) else {
            throw IOSSharedQuickActionError.unresolvedInput
        }
        guard let prompt = action.filled(with: input) else { throw IOSSharedQuickActionError.unresolvedInput }
        return try validatedQuickActionPrompt(prompt)
    }

    private func validatedQuickActionPrompt(_ value: String) throws -> String {
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw IOSSharedQuickActionError.emptyPrompt }
        guard prompt.count <= 2_000 else { throw IOSSharedQuickActionError.promptTooLong }
        guard WatchQuickAction.supports(prompt: prompt) else { throw IOSSharedQuickActionError.unsupportedPrompt }
        return prompt
    }

    private func updateSavedQuickMessages(_ transform: (inout [[String: Any]]) -> Void) throws {
        // Merge into the current snapshot so edits cannot overwrite unrelated settings.
        let json = IosSettingsJsonBridge.shared.encode(settings: snapshot)
        guard var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw IOSSharedQuickActionError.persistenceFailed("无法读取常用任务设置，请重试。")
        }
        var messages = object["quickMessages"] as? [[String: Any]] ?? []
        transform(&messages)
        object["quickMessages"] = messages
        let data = try JSONSerialization.data(withJSONObject: object)
        let settings = try IosSettingsJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
        guard restoreSnapshot(settings) else {
            throw IOSSharedQuickActionError.persistenceFailed(
                credentialPersistenceError ?? "常用任务未能保存，请重试。"
            )
        }
    }
}
