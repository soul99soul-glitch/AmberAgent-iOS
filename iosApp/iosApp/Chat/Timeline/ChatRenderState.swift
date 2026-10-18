import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

final class ChatLiveTailModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var message: UIMessage
    private(set) var isGenerationActive: Bool
    private(set) var renderState: ChatRenderState
    private(set) var revision: Int = 0
    private var lastSourceRevision: Int?

    init(message: UIMessage, isGenerationActive: Bool, renderState: ChatRenderState) {
        self.message = message
        self.isGenerationActive = isGenerationActive
        self.renderState = renderState
    }

    func update(
        message: UIMessage,
        isGenerationActive: Bool,
        renderState: ChatRenderState,
        sourceRevision: Int? = nil
    ) {
        if let sourceRevision,
           sourceRevision == lastSourceRevision,
           self.isGenerationActive == isGenerationActive,
           self.renderState == renderState {
            return
        }
        objectWillChange.send()
        self.message = message
        self.isGenerationActive = isGenerationActive
        self.renderState = renderState
        lastSourceRevision = sourceRevision
        revision &+= 1
    }
}

enum ChatRendererMode: String {
    case staticMarkdown
    case streamingMarkdown
    case frozen
}

struct ChatRenderState: Equatable {
    var rendererMode: ChatRendererMode
    var hasEverStreamed: Bool
    var liveRenderingEnabled: Bool
    var frozenMarkdownSnapshot: String?
}

final class ChatRenderStateStore {
    private var visibleMessageIDs: Set<String> = []
    private var frozenMessageIDs: Set<String> = []
    private var frozenMarkdownByMessageID: [String: String] = [:]
    private var liveTailModelsByMessageID: [String: ChatLiveTailModel] = [:]

    func existingLiveTailModel(messageID: String) -> ChatLiveTailModel? {
        liveTailModelsByMessageID[messageID]
    }

    func stateForRow(_ row: ChatMessageRowModel, isLiveRenderingFarFromBottom: Bool) -> ChatRenderState {
        let renderer: ChatTimelineRendererKind = row.role == MessageRole.assistant && (row.hasEverStreamed || row.isStreaming)
            ? .streamingAssistantMarkdown
            : (row.role == MessageRole.user ? .user : .staticAssistantMarkdown)
        return stateForEntry(
            ChatTimelineMessageEntry(
                id: "message-\(row.messageId)",
                messageId: row.messageId,
                message: row.message,
                role: row.role,
                index: row.index,
                isLast: row.isLast,
                isStreaming: row.isStreaming,
                hasEverStreamed: row.hasEverStreamed,
                canAnimateInsertion: row.canAnimateInsertion,
                renderer: renderer,
                renderToken: row.messageId,
                isAssistantContinuation: row.isAssistantContinuation
            ),
            isLiveRenderingFarFromBottom: isLiveRenderingFarFromBottom
        )
    }

    func stateForEntry(_ entry: ChatTimelineMessageEntry, isLiveRenderingFarFromBottom: Bool) -> ChatRenderState {
        let row = entry.rowModel
        guard entry.renderer == .streamingAssistantMarkdown else {
            return ChatRenderState(
                rendererMode: .staticMarkdown,
                hasEverStreamed: false,
                liveRenderingEnabled: true,
                frozenMarkdownSnapshot: nil
            )
        }

        let frozen = frozenMessageIDs.contains(row.messageId)
        let live = row.isLast &&
            row.role == MessageRole.assistant &&
            !isLiveRenderingFarFromBottom &&
            !frozen
        return ChatRenderState(
            rendererMode: live ? .streamingMarkdown : .frozen,
            hasEverStreamed: true,
            liveRenderingEnabled: live,
            frozenMarkdownSnapshot: live ? nil : frozenMarkdownByMessageID[row.messageId]
        )
    }

    func liveTailModel(
        for row: ChatMessageRowModel,
        renderState: ChatRenderState,
        isGenerationActive: Bool
    ) -> ChatLiveTailModel? {
        guard row.isLast,
              row.role == MessageRole.assistant,
              renderState.hasEverStreamed else { return nil }
        if let model = liveTailModelsByMessageID[row.messageId] {
            return model
        }
        guard row.isStreaming || isGenerationActive else { return nil }
        let model = ChatLiveTailModel(
            message: row.message,
            isGenerationActive: isGenerationActive,
            renderState: renderState
        )
        liveTailModelsByMessageID[row.messageId] = model
        return model
    }

    /// 行进入视口即解冻并丢弃冻结快照:可见的行必须显示真实内容,
    /// 不能停在离屏时冻结的旧文本上。
    @discardableResult
    func markVisible(_ messageID: String) -> Bool {
        let changed = !visibleMessageIDs.contains(messageID) ||
            frozenMessageIDs.contains(messageID) ||
            frozenMarkdownByMessageID[messageID] != nil
        visibleMessageIDs.insert(messageID)
        frozenMessageIDs.remove(messageID)
        frozenMarkdownByMessageID.removeValue(forKey: messageID)
        return changed
    }

    func freeze(messageID: String, latestText: String?) {
        visibleMessageIDs.remove(messageID)
        frozenMessageIDs.insert(messageID)
        if let latestText {
            frozenMarkdownByMessageID[messageID] = latestText
        }
    }

    func retain(ids: Set<String>) {
        visibleMessageIDs = visibleMessageIDs.intersection(ids)
        frozenMessageIDs = frozenMessageIDs.intersection(ids)
        frozenMarkdownByMessageID = frozenMarkdownByMessageID.filter { ids.contains($0.key) }
        liveTailModelsByMessageID = liveTailModelsByMessageID.filter { ids.contains($0.key) }
    }

    func removeAll() {
        visibleMessageIDs.removeAll()
        frozenMessageIDs.removeAll()
        frozenMarkdownByMessageID.removeAll()
        liveTailModelsByMessageID.removeAll()
    }
}

