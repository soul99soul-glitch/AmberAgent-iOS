import Foundation
import Shared

extension UIMessage {
    var singleNonEmptyTextPart: String? {
        var result: String?
        for part in parts {
            guard let text = part as? UIMessagePart.Text, !text.text.isEmpty else { continue }
            guard result == nil else { return nil }
            result = text.text
        }
        return result
    }
}

struct ChatMessageAnchor: Hashable, Sendable {
    let conversationID: String
    let messageID: String
    let toolCallID: String?
    let requestToken: UUID?

    init(
        conversationID: String,
        messageID: String,
        toolCallID: String? = nil,
        requestToken: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.toolCallID = toolCallID
        self.requestToken = requestToken
    }
}

enum ChatImageGenerationAnchorTarget {
    static func id(messageID: String, toolCallID: String) -> String {
        "image-tool-\(messageID)-\(toolCallID)"
    }
}

enum ChatToolCallAnchorTarget {
    static func id(messageID: String, toolCallID: String) -> String {
        "tool-call-\(messageID)-\(toolCallID)"
    }
}

enum ChatImageGenerationResumeState: Equatable, Sendable {
    case running
    case completed
}

struct ChatImageGenerationResumeContext: Equatable, Sendable, Identifiable {
    let id: String
    let conversationID: String
    let messageID: String
    let toolCallID: String
    let prompt: String
    let state: ChatImageGenerationResumeState
    let updatedAt: Date
}

enum ChatImageGenerationResumeProjection {
    static func latest(
        in messages: [UIMessage],
        conversationID: String,
        isGenerationActive: Bool
    ) -> ChatImageGenerationResumeContext? {
        preferred(in: contexts(
            in: messages,
            conversationID: conversationID,
            isGenerationActive: isGenerationActive
        ))
    }

    static func matching(
        in messages: [UIMessage],
        conversationID: String,
        messageID: String,
        toolCallID: String,
        isGenerationActive: Bool
    ) -> ChatImageGenerationResumeContext? {
        contexts(
            in: messages,
            conversationID: conversationID,
            isGenerationActive: isGenerationActive
        ).first {
            $0.messageID == messageID && $0.toolCallID == toolCallID
        }
    }

    private static func contexts(
        in messages: [UIMessage],
        conversationID: String,
        isGenerationActive: Bool
    ) -> [ChatImageGenerationResumeContext] {
        messages.enumerated().flatMap { index, message -> [ChatImageGenerationResumeContext] in
            guard message.role == MessageRole.assistant else { return [] }
            let messageID = ChatMessageProjector.messageId(for: message)
            return message.parts.compactMap { part -> ChatImageGenerationResumeContext? in
                guard let tool = part as? UIMessagePart.Tool,
                      tool.toolName == "generate_image" else {
                    return nil
                }

                let state: ChatImageGenerationResumeState
                let timestamp: Kotlinx_datetimeLocalDateTime
                if tool.output.contains(where: { $0 is UIMessagePart.Image }) {
                    state = .completed
                    timestamp = message.finishedAt ?? message.createdAt
                } else if tool.output.isEmpty,
                          isGenerationActive,
                          index == messages.count - 1 {
                    state = .running
                    timestamp = message.createdAt
                } else {
                    return nil
                }
                guard let updatedAt = date(from: timestamp) else { return nil }

                return ChatImageGenerationResumeContext(
                    id: "\(conversationID)|\(messageID)|\(tool.toolCallId)",
                    conversationID: conversationID,
                    messageID: messageID,
                    toolCallID: tool.toolCallId,
                    prompt: prompt(from: tool.input),
                    state: state,
                    updatedAt: updatedAt
                )
            }
        }
    }

    static func preferred(
        in contexts: [ChatImageGenerationResumeContext]
    ) -> ChatImageGenerationResumeContext? {
        contexts.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .running }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }.first
    }

    private static func prompt(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String else {
            return trimmed
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(from localDateTime: Kotlinx_datetimeLocalDateTime) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = Int(localDateTime.year)
        components.month = Int(localDateTime.month.ordinal) + 1
        components.day = Int(localDateTime.day)
        components.hour = Int(localDateTime.hour)
        components.minute = Int(localDateTime.minute)
        components.second = Int(localDateTime.second)
        components.nanosecond = Int(localDateTime.nanosecond)
        return components.date
    }
}

enum ChatImageGenerationResumeConsumption {
    static let viewedCompletionIDKey = "app.amber.ios.home.viewedImageGeneration.v1"

    @discardableResult
    static func markViewedIfCompleted(
        anchor: ChatMessageAnchor,
        messages: [UIMessage],
        isGenerationActive: Bool,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard let toolCallID = anchor.toolCallID,
              let context = ChatImageGenerationResumeProjection.matching(
                in: messages,
                conversationID: anchor.conversationID,
                messageID: anchor.messageID,
                toolCallID: toolCallID,
                isGenerationActive: isGenerationActive
              ),
              context.state == .completed else {
            return nil
        }
        userDefaults.set(context.id, forKey: viewedCompletionIDKey)
        return context.id
    }
}

