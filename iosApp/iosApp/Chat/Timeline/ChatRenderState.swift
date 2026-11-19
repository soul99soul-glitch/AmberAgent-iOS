import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

final class ChatLiveTailModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var message: UIMessage
    private(set) var displayTexts: [Int: String]
    private(set) var isGenerationActive: Bool
    private(set) var renderState: ChatRenderState
    private(set) var revision: Int = 0
    private var lastSourceRevision: Int?

    init(message: UIMessage, isGenerationActive: Bool, renderState: ChatRenderState, displayTexts: [Int: String]? = nil) {
        self.message = message
        self.displayTexts = displayTexts ?? IOSSubAgentOutputProjection.unpreparedDisplayTexts(in: message)
        self.isGenerationActive = isGenerationActive
        self.renderState = renderState
    }

    func update(
        message: UIMessage,
        isGenerationActive: Bool,
        renderState: ChatRenderState,
        sourceRevision: Int? = nil,
        displayTexts: [Int: String]? = nil
    ) {
        if let sourceRevision,
           sourceRevision == lastSourceRevision,
           self.isGenerationActive == isGenerationActive,
           self.renderState == renderState {
            return
        }
        objectWillChange.send()
        self.displayTexts = displayTexts ?? IOSSubAgentOutputProjection.unpreparedDisplayTexts(in: message)
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
    private(set) var stateMutationCount: UInt64 = 0

    func existingLiveTailModel(messageID: String) -> ChatLiveTailModel? {
        liveTailModelsByMessageID[messageID]
    }

    func stateForRow(_ row: ChatMessageRowModel, isLiveRenderingFarFromBottom: Bool,
                     isLiveTask: Bool = false) -> ChatRenderState {
        let usesStreamingMarkdown = row.role == MessageRole.assistant && (row.hasEverStreamed || row.isStreaming)
        return resolveState(
            messageId: row.messageId,
            role: row.role,
            isLast: row.isLast,
            usesStreamingMarkdown: usesStreamingMarkdown,
            isLiveRenderingFarFromBottom: isLiveRenderingFarFromBottom,
            isLiveTask: isLiveTask
        )
    }

    func stateForEntry(_ entry: ChatTimelineMessageEntry, isLiveRenderingFarFromBottom: Bool,
                       isLiveTask: Bool = false) -> ChatRenderState {
        resolveState(
            messageId: entry.messageId,
            role: entry.role,
            isLast: entry.isLast,
            usesStreamingMarkdown: entry.renderer == .streamingAssistantMarkdown,
            isLiveRenderingFarFromBottom: isLiveRenderingFarFromBottom,
            isLiveTask: isLiveTask
        )
    }

    private func resolveState(
        messageId: String,
        role: MessageRole,
        isLast: Bool,
        usesStreamingMarkdown: Bool,
        isLiveRenderingFarFromBottom: Bool,
        isLiveTask: Bool
    ) -> ChatRenderState {
        guard usesStreamingMarkdown else {
            return ChatRenderState(
                rendererMode: .staticMarkdown,
                hasEverStreamed: false,
                liveRenderingEnabled: true,
                frozenMarkdownSnapshot: nil
            )
        }

        let frozen = frozenMessageIDs.contains(messageId)
        let live = (isLast || isLiveTask) &&
            role == MessageRole.assistant &&
            !isLiveRenderingFarFromBottom &&
            !frozen
        return ChatRenderState(
            rendererMode: live ? .streamingMarkdown : .frozen,
            hasEverStreamed: true,
            liveRenderingEnabled: live,
            frozenMarkdownSnapshot: live ? nil : frozenMarkdownByMessageID[messageId]
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
            renderState: renderState,
            displayTexts: row.displayTexts
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
        if changed {
            stateMutationCount &+= 1
        }
        return changed
    }

    func freeze(messageID: String, latestText: String?) {
        visibleMessageIDs.remove(messageID)
        frozenMessageIDs.insert(messageID)
        if let latestText {
            frozenMarkdownByMessageID[messageID] = latestText
        }
        stateMutationCount &+= 1
    }

    func retain(ids: Set<String>) {
        let previousFrozenCount = frozenMessageIDs.count
        let previousSnapshotCount = frozenMarkdownByMessageID.count
        visibleMessageIDs = visibleMessageIDs.intersection(ids)
        frozenMessageIDs = frozenMessageIDs.intersection(ids)
        frozenMarkdownByMessageID = frozenMarkdownByMessageID.filter { ids.contains($0.key) }
        liveTailModelsByMessageID = liveTailModelsByMessageID.filter { ids.contains($0.key) }
        if frozenMessageIDs.count != previousFrozenCount ||
            frozenMarkdownByMessageID.count != previousSnapshotCount {
            stateMutationCount &+= 1
        }
    }

    func removeAll() {
        let hadState = !visibleMessageIDs.isEmpty ||
            !frozenMessageIDs.isEmpty ||
            !frozenMarkdownByMessageID.isEmpty ||
            !liveTailModelsByMessageID.isEmpty
        visibleMessageIDs.removeAll()
        frozenMessageIDs.removeAll()
        frozenMarkdownByMessageID.removeAll()
        liveTailModelsByMessageID.removeAll()
        if hadState {
            stateMutationCount &+= 1
        }
    }
}

