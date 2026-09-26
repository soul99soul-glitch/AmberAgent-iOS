import Foundation
@preconcurrency import Shared

struct ConversationRecap: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case decision
            case milestone
            case failure
            case artifact
        }

        let kind: Kind
        let title: String
        let messageRef: String
        /// The generated short reference resolved against the exact input branch.
        /// A nil value means the model cited a reference outside that input.
        let messageID: String?
    }

    let overview: String
    let nodes: [Node]
    let nextSteps: [String]
    let conversationID: String
    let coveredThroughMessageID: String
    let branchID: String
    let generatedAt: Date

    func projectingMessageReferences(to messages: [UIMessage]) -> ConversationRecap {
        let currentMessageIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
        return ConversationRecap(
            overview: overview,
            nodes: nodes.map { node in
                Node(
                    kind: node.kind,
                    title: node.title,
                    messageRef: node.messageRef,
                    messageID: node.messageID.flatMap { currentMessageIDs.contains($0) ? $0 : nil }
                )
            },
            nextSteps: nextSteps,
            conversationID: conversationID,
            coveredThroughMessageID: coveredThroughMessageID,
            branchID: branchID,
            generatedAt: generatedAt
        )
    }

    /// Branch identity includes selected variants only, so appending new nodes
    /// leaves it stable while selecting another message variant changes it.
    static func branchIdentifier(for conversation: Conversation, messages: [UIMessage]? = nil) -> String {
        let messageIDs = messages.map { Set($0.map { $0.id.toHexDashString() }) }
        let selections = conversation.messageNodes.compactMap { node -> String? in
            guard node.messages.count > 1 else { return nil }
            let selectedMessage: UIMessage?
            if let messageIDs {
                selectedMessage = node.messages.first {
                    messageIDs.contains($0.id.toHexDashString())
                }
            } else {
                let selectedIndex = Int(node.selectIndex)
                selectedMessage = node.messages.indices.contains(selectedIndex) ? node.messages[selectedIndex] : nil
            }
            guard let selectedMessage else { return nil }
            return "\(node.id.toHexDashString()):\(selectedMessage.id.toHexDashString())"
        }
        return selections.isEmpty ? "main" : selections.joined(separator: "|")
    }
}

struct ConversationRecapGenerationInput: Equatable {
    let prompt: String
    let messageIDsByReference: [String: String]
    let coveredThroughMessageID: String
    let branchID: String
}

enum ConversationRecapLogic {
    static let minimumUserMessageCount = 3
    static let recentMessageLimit = 32
    static let messageBodyLimit = 1_500
    static let toolInputLimit = 300
    static let toolOutputLimit = 300

    private struct ModelResponse: Decodable {
        struct ModelNode: Decodable {
            let kind: String
            let title: String
            let messageRef: String
        }

        let overview: String
        let nodes: [ModelNode]
        let nextSteps: [String]
    }

    enum ParseError: LocalizedError, Equatable {
        case invalidJSON
        case invalidContent

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                "回顾内容格式错误，请重试。"
            case .invalidContent:
                "回顾内容不完整，请重试。"
            }
        }
    }

    static func eligible(messages: [UIMessage]) -> Bool {
        messages.filter {
            $0.role == MessageRole.user && ChatMessageProjector.isConversationMessage($0)
        }.count >= minimumUserMessageCount
    }

    static func isStale(
        recap: ConversationRecap,
        messages: [UIMessage],
        branchID: String
    ) -> Bool {
        guard recap.branchID == branchID,
              messages.contains(where: {
                  ChatMessageProjector.messageId(for: $0) == recap.coveredThroughMessageID
              }),
              let lastMessage = messages.last else {
            return true
        }
        return ChatMessageProjector.messageId(for: lastMessage) != recap.coveredThroughMessageID
    }

    static func makeInput(
        previousRecap: ConversationRecap?,
        messages: [UIMessage],
        conversationID: String,
        branchID: String,
        compactSummary: String?
    ) -> ConversationRecapGenerationInput? {
        guard let coveredThroughMessageID = messages.last.map(ChatMessageProjector.messageId(for:)) else {
            return nil
        }

        let numberedMessages: [(index: Int, reference: String, messageID: String, role: String, text: String)] =
            messages.enumerated().compactMap { index, message in
                guard ChatMessageProjector.isConversationMessage(message) else { return nil }
                let role: String
                if message.role == MessageRole.user {
                    role = "User"
                } else if message.role == MessageRole.assistant {
                    role = "Assistant"
                } else {
                    return nil
                }
                let text = messageText(message)
                guard !text.isEmpty else { return nil }
                let reference = "m\(index + 1)"
                return (index, reference, ChatMessageProjector.messageId(for: message), role, text)
            }

        let coveredIndex = messages.firstIndex {
            ChatMessageProjector.messageId(for: $0) == previousRecap?.coveredThroughMessageID
        }
        let sameBranchIncrement = previousRecap?.conversationID == conversationID
            && previousRecap?.branchID == branchID
            && coveredIndex != nil
        let unboundedTranscript = sameBranchIncrement
            ? numberedMessages.filter { $0.index > coveredIndex! }
            : Array(numberedMessages.suffix(recentMessageLimit))
        let transcriptMessages = Array(unboundedTranscript.suffix(recentMessageLimit))
        let currentReferenceByMessageID = Dictionary(
            numberedMessages.map { ($0.messageID, $0.reference) },
            uniquingKeysWith: { first, _ in first }
        )
        let prior = previousRecap?.conversationID == conversationID ? previousRecap : nil
        let mappedPriorNodes = prior?.nodes.map { node -> ConversationRecap.Node in
            guard let messageID = node.messageID,
                  let currentReference = currentReferenceByMessageID[messageID] else {
                return ConversationRecap.Node(
                    kind: node.kind,
                    title: node.title,
                    messageRef: "unavailable",
                    messageID: nil
                )
            }
            return ConversationRecap.Node(
                kind: node.kind,
                title: node.title,
                messageRef: currentReference,
                messageID: messageID
            )
        } ?? []
        let priorByReference = Dictionary(
            mappedPriorNodes.compactMap { node -> (String, String)? in
                guard let messageID = node.messageID else { return nil }
                return (node.messageRef, messageID)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var referenceMap = priorByReference
        for message in transcriptMessages {
            referenceMap[message.reference] = message.messageID
        }

        let compact = compactSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactSection = compact.flatMap { $0.isEmpty ? nil : """
            <context_summary>
            \($0)
            </context_summary>
            """ } ?? ""
        let priorSection = prior.map { recap in
            let nodeLines = mappedPriorNodes.map {
                "- [\($0.kind.rawValue)] \($0.title) (\($0.messageID == nil ? "source unavailable" : $0.messageRef))"
            }.joined(separator: "\n")
            let nextLines = recap.nextSteps.map { "- \($0)" }.joined(separator: "\n")
            return """
            <previous_recap>
            Overview: \(recap.overview)
            Key nodes:
            \(nodeLines)
            Next steps:
            \(nextLines)
            </previous_recap>
            """
        } ?? ""
        let branchCorrection = previousRecap.map { recap in
            recap.branchID == branchID ? "" : "The previous recap belongs to another branch. Re-evaluate it against the current branch; do not cite a source marked unavailable."
        } ?? ""
        let transcript = transcriptMessages.map {
            "\($0.reference) \($0.role): \($0.text)"
        }.joined(separator: "\n\n")
        let locale = Locale.current.localizedString(forIdentifier: Locale.current.identifier)
            ?? Locale.current.identifier
        let prompt = """
            Create a structured recap of this conversation in the user's primary language (\(locale)).
            Return only valid JSON with this exact shape:
            {"overview":"...","nodes":[{"kind":"decision|milestone|failure|artifact","title":"...","messageRef":"m1"}],"nextSteps":["..."]}
            The overview is one paragraph of at most about 120 characters, covering what was done, the result, and unresolved points.
            Include 3 to 8 important nodes and 0 to 3 actionable next steps. Use only message references shown in the transcript or previous recap.
            Preserve still-relevant previous nodes and next steps, then incorporate the new messages. A node's messageRef must identify its source message.
            Do not invent events or references.
            \(branchCorrection)
            \(compactSection)
            \(priorSection)
            <new_messages>
            \(transcript)
            </new_messages>
            """
        return ConversationRecapGenerationInput(
            prompt: prompt,
            messageIDsByReference: referenceMap,
            coveredThroughMessageID: coveredThroughMessageID,
            branchID: branchID
        )
    }

    static func parse(
        _ raw: String,
        messageIDsByReference: [String: String],
        conversationID: String,
        coveredThroughMessageID: String,
        branchID: String,
        generatedAt: Date = Date()
    ) throws -> ConversationRecap {
        guard let objectJSON = IOSDeepReadDraftGenerator.extractJSONObject(raw),
              let data = objectJSON.data(using: .utf8) else {
            throw ParseError.invalidJSON
        }
        let response: ModelResponse
        do {
            response = try JSONDecoder().decode(ModelResponse.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        let overview = response.overview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let validNodes = response.nodes.compactMap { node -> ConversationRecap.Node? in
            guard let kind = ConversationRecap.Node.Kind(rawValue: node.kind) else { return nil }
            return ConversationRecap.Node(
                kind: kind,
                title: node.title.trimmingCharacters(in: .whitespacesAndNewlines),
                messageRef: node.messageRef,
                messageID: messageIDsByReference[node.messageRef]
            )
        }
        let boundedNodes = Array(validNodes.prefix(8))
        guard !overview.isEmpty,
              !boundedNodes.isEmpty,
              boundedNodes.allSatisfy({ !$0.title.isEmpty }),
              response.nextSteps.count <= 3,
              response.nextSteps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ParseError.invalidContent
        }
        return ConversationRecap(
            overview: String(overview.prefix(120)),
            nodes: boundedNodes,
            nextSteps: response.nextSteps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            conversationID: conversationID,
            coveredThroughMessageID: coveredThroughMessageID,
            branchID: branchID,
            generatedAt: generatedAt
        )
    }

    private static func messageText(_ message: UIMessage) -> String {
        let body = message.parts.compactMap { part -> String? in
            if let text = part as? UIMessagePart.Text {
                return text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let tool = part as? UIMessagePart.Tool {
                let input = String(
                    tool.input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(toolInputLimit)
                )
                let output = String(
                    tool.output.compactMap(messagePartText).joined(separator: "\n").prefix(toolOutputLimit)
                )
                return [
                    "Tool: \(tool.toolName)",
                    input.isEmpty ? nil : "Input: \(input)",
                    output.isEmpty ? nil : "Output: \(output)"
                ].compactMap { $0 }.joined(separator: "\n")
            }
            if let image = part as? UIMessagePart.Image {
                let url = image.url
                return url.hasPrefix("http://") || url.hasPrefix("https://")
                    ? "[图片: \(url)]"
                    : "[图片]"
            }
            if let document = part as? UIMessagePart.Document {
                return "[文件: \(document.fileName)]"
            }
            if let miniApp = part as? UIMessagePart.MiniApp {
                return "[交互成果: \(miniApp.title)]"
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        return String(body.prefix(messageBodyLimit))
    }

    private static func messagePartText(_ part: UIMessagePart) -> String? {
        if let text = part as? UIMessagePart.Text {
            return text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let image = part as? UIMessagePart.Image {
            let url = image.url
            return url.hasPrefix("http://") || url.hasPrefix("https://")
                ? "[图片: \(url)]"
                : "[图片]"
        }
        if let document = part as? UIMessagePart.Document {
            return "[文件: \(document.fileName)]"
        }
        return nil
    }
}
