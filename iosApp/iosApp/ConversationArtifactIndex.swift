import Foundation
import Shared

/// 从当前会话分支的工具结果生成产物架索引，不读取存储或其他分支。
struct ConversationArtifactIndex: Equatable {
    struct Source: Equatable, Hashable, Sendable {
        let messageID: String
        let turn: Int
        let toolCallID: String
    }

    struct Image: Equatable, Identifiable {
        let id: String
        let url: String
        let prompt: String?
        let source: Source
    }

    struct FileVersion: Equatable, Identifiable {
        let id: String
        let source: Source
        /// 仅保留本次工具明确提供的完整文本。
        let content: String?
    }

    struct FileGroup: Equatable, Identifiable {
        var id: String { path }
        let path: String
        var versions: [FileVersion]
    }

    struct WebPage: Equatable, Identifiable {
        let id: String
        let title: String
        let url: String?
        let preview: String?
        let source: Source
    }

    let images: [Image]
    let files: [FileGroup]
    let webPages: [WebPage]

    /// 同一路径的多版文件在产物架里仍算一个产物。
    var count: Int {
        images.count + files.count + webPages.count
    }

    static func make(from messages: [UIMessage]) -> ConversationArtifactIndex {
        var images: [Image] = []
        var files: [FileGroup] = []
        var fileIndices: [String: Int] = [:]
        var webPages: [WebPage] = []
        var webPageIndices: [String: Int] = [:]
        var seenTools: Set<ToolIdentity> = []
        var turn = 0

        for message in messages {
            guard ChatMessageProjector.isConversationMessage(message) else { continue }
            if message.role == MessageRole.user {
                turn += 1
                continue
            }
            guard message.role == MessageRole.assistant else { continue }

            let messageID = ChatMessageProjector.messageId(for: message)
            for case let tool as UIMessagePart.Tool in message.parts {
                let identity = ToolIdentity(messageID: messageID, toolCallID: tool.toolCallId)
                guard !tool.toolCallId.isEmpty, seenTools.insert(identity).inserted else { continue }
                let source = Source(
                    messageID: messageID,
                    turn: max(turn, 1),
                    toolCallID: tool.toolCallId
                )
                switch tool.toolName {
                case "generate_image":
                    let input = inputObject(tool.input)
                    let prompt = (input["prompt"] as? String)?.nilIfBlank
                    for (imageIndex, image) in tool.output.compactMap({ $0 as? UIMessagePart.Image }).enumerated() {
                        images.append(Image(
                            id: "\(messageID):\(tool.toolCallId):image:\(imageIndex)",
                            url: image.url,
                            prompt: prompt,
                            source: source
                        ))
                    }
                case "workspace_file_write":
                    let input = inputObject(tool.input)
                    let output = ChatToolOutputFormatter.analysis(for: tool).firstJSONObject
                    guard let output, output["ok"] as? Bool == true,
                          let path = canonicalWorkspacePath(
                              output["path"] as? String ?? input["path"] as? String
                          ) else { continue }
                    let content: String?
                    if let candidate = input["content"] as? String,
                       let size = output["size_bytes"] as? Int,
                       candidate.utf8.count == size {
                        content = candidate
                    } else {
                        content = nil
                    }
                    appendFileVersion(
                        path: path,
                        content: content,
                        source: source,
                        files: &files,
                        fileIndices: &fileIndices
                    )
                case "workspace_file_edit":
                    let input = inputObject(tool.input)
                    let output = ChatToolOutputFormatter.analysis(for: tool).firstJSONObject
                    guard let output, output["ok"] as? Bool == true,
                          output["changed"] as? Bool == true,
                          let path = canonicalWorkspacePath(
                              output["path"] as? String ?? input["path"] as? String
                          ) else { continue }
                    // workspace 可被其他对话或终端改写，有限 diff 回执不足以证明全文。
                    appendFileVersion(
                        path: path,
                        content: nil,
                        source: source,
                        files: &files,
                        fileIndices: &fileIndices
                    )
                case "scrape_web":
                    let output = ChatToolOutputFormatter.analysis(for: tool).firstJSONObject
                    guard let output, isSuccessful(output),
                          let url = nonBlank(output["url"] as? String) else { continue }
                    let title = nonBlank(output["title"] as? String) ?? url
                    appendWebPage(WebPage(
                        id: "web:\(url)",
                        title: title,
                        url: url,
                        preview: nonBlank(output["content"] as? String).map(preview),
                        source: source
                    ), url: url, pages: &webPages, indices: &webPageIndices)
                case "wm_open", "wm_extract":
                    let output = ChatToolOutputFormatter.analysis(for: tool).firstJSONObject
                    guard let output, let page = webMountPage(output),
                          let url = nonBlank(page.url) ?? nonBlank(page.currentURL),
                          isSuccessful(output) else { continue }
                    let title = nonBlank(page.title) ?? url
                    appendWebPage(WebPage(
                        id: "web:\(url)",
                        title: title,
                        url: url,
                        preview: nonBlank(page.preview).map(preview),
                        source: source
                    ), url: url, pages: &webPages, indices: &webPageIndices)
                default:
                    continue
                }
            }
        }

        return ConversationArtifactIndex(images: images, files: files, webPages: webPages)
    }

    /// 仅当消息和 tool part 仍在当前分支中时返回定位锚点。
    static func anchor(
        for source: Source,
        conversationID: String,
        messages: [UIMessage],
        requestToken: UUID? = nil
    ) -> ChatMessageAnchor? {
        guard let message = messages.first(where: {
            ChatMessageProjector.messageId(for: $0) == source.messageID
        }),
              message.parts.contains(where: {
                  ($0 as? UIMessagePart.Tool)?.toolCallId == source.toolCallID
              }) else {
            return nil
        }
        return ChatMessageAnchor(
            conversationID: conversationID,
            messageID: source.messageID,
            toolCallID: source.toolCallID,
            requestToken: requestToken
        )
    }

    private struct WebMountPage {
        let url: String?
        let currentURL: String?
        let title: String?
        let preview: String?
    }

    private struct ToolIdentity: Hashable {
        let messageID: String
        let toolCallID: String
    }

    private static func appendWebPage(
        _ page: WebPage,
        url: String,
        pages: inout [WebPage],
        indices: inout [String: Int]
    ) {
        if let index = indices[url] {
            pages[index] = page
        } else {
            indices[url] = pages.count
            pages.append(page)
        }
    }

    private static func appendFileVersion(
        path: String,
        content: String?,
        source: Source,
        files: inout [FileGroup],
        fileIndices: inout [String: Int]
    ) {
        let version = FileVersion(
            id: "\(source.messageID):\(source.toolCallID)",
            source: source,
            content: content
        )
        if let index = fileIndices[path] {
            files[index].versions.append(version)
        } else {
            fileIndices[path] = files.count
            files.append(FileGroup(path: path, versions: [version]))
        }
    }

    private static func canonicalWorkspacePath(_ rawPath: String?) -> String? {
        guard var path = nonBlank(rawPath) else { return nil }
        path = path.replacingOccurrences(of: "\\", with: "/")
        if path == "/workspace" {
            return nil
        } else if path.hasPrefix("/workspace/") {
            path.removeFirst("/workspace/".count)
        }
        guard !path.hasPrefix("/"), !path.contains(":") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    private static func inputObject(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func isSuccessful(_ object: [String: Any]) -> Bool {
        if let ok = object["ok"] as? Bool { return ok }
        guard let status = (object["status"] as? String)?.lowercased() else { return false }
        return ["ok", "success", "succeeded", "completed"].contains(status)
    }

    private static func webMountPage(_ output: [String: Any]) -> WebMountPage? {
        let result: [String: Any]
        if let object = output["result"] as? [String: Any] {
            result = object
        } else if let raw = output["result"] as? String,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = object
        } else {
            result = [:]
        }
        let page = (output["page"] as? [String: Any]) ?? (result["page"] as? [String: Any]) ?? [:]
        let state = (output["state"] as? [String: Any]) ?? [:]
        let resultState = (result["state"] as? [String: Any]) ?? [:]
        let url = page["url"] as? String ?? result["url"] as? String
        let currentURL = output["current_url"] as? String
            ?? output["url"] as? String
            ?? state["current_url"] as? String
            ?? resultState["current_url"] as? String
        let title = page["title"] as? String
            ?? output["title"] as? String
            ?? result["title"] as? String
            ?? state["title"] as? String
            ?? resultState["title"] as? String
        let preview = output["visible_text"] as? String
            ?? output["text"] as? String
            ?? result["visible_text"] as? String
            ?? result["text"] as? String
            ?? result["content"] as? String
        guard url != nil || currentURL != nil || title != nil else { return nil }
        return WebMountPage(url: url, currentURL: currentURL, title: title, preview: preview)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func preview(_ value: String) -> String {
        String(value.prefix(280))
    }
}
