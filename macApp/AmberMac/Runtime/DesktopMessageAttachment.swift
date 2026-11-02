import Foundation

struct DesktopMessageAttachment: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case text
        case inlineText = "inline_text"
    }
    let name: String
    let mimeType: String
    let kind: Kind
    let dataURL: String?
    let text: String?

    init(name: String, mimeType: String = "text/plain", kind: Kind, dataURL: String? = nil, text: String? = nil) {
        self.name = name
        self.mimeType = mimeType
        self.kind = kind
        self.dataURL = dataURL
        self.text = text
    }

    init(_ document: DesktopImportedDocument) {
        name = document.name
        mimeType = document.image?.mimeType ?? "text/plain"
        kind = document.image == nil ? .text : .image
        dataURL = document.image?.dataURL
        text = document.image == nil ? document.text : nil
    }

    static func inlineText(_ value: String, name: String = "正文片段") -> Self {
        Self(name: name, mimeType: "text/plain", kind: .inlineText, text: value)
    }

    static func inlineMarker(for index: Int, name: String) -> String {
        "![\(name)](attachment://\(index))"
    }

    static func composeSubmission(
        draft: String,
        documents: [DesktopImportedDocument],
        anchors: [UUID: String] = [:]
    ) -> (text: String, attachments: [DesktopMessageAttachment]) {
        let baseAttachments = documents.map(DesktopMessageAttachment.init)
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty, !documents.isEmpty, !draft.contains("](attachment://") else {
            return (trimmedDraft, baseAttachments)
        }
        let indexedImages = documents.enumerated().filter { $0.element.kind == .image }
        guard !indexedImages.isEmpty else { return (trimmedDraft, baseAttachments) }

        var anchoredOffsets: [(index: Int, name: String, offset: Int, prefix: String)] = []
        var lastOffset = 0
        for (index, doc) in indexedImages {
            guard let prefix = anchors[doc.id], draft.hasPrefix(prefix) else {
                return (trimmedDraft, baseAttachments)
            }
            let count = prefix.count
            guard count >= lastOffset else { return (trimmedDraft, baseAttachments) }
            lastOffset = count
            anchoredOffsets.append((index, doc.name, count, prefix))
        }

        let distinctPrefixes = Set(anchoredOffsets.map { $0.prefix.trimmingCharacters(in: .whitespacesAndNewlines) })
        let hasInteriorAnchor = anchoredOffsets.contains { item in
            let before = item.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(draft.dropFirst(item.offset)).trimmingCharacters(in: .whitespacesAndNewlines)
            return !before.isEmpty && !after.isEmpty
        }
        guard hasInteriorAnchor || distinctPrefixes.count >= 2 else {
            return (trimmedDraft, baseAttachments)
        }

        var result = ""
        var cursor = draft.startIndex
        var currentOffset = 0
        for item in anchoredOffsets {
            let targetIndex = draft.index(cursor, offsetBy: item.offset - currentOffset)
            result += draft[cursor..<targetIndex]
            result += inlineMarker(for: item.index, name: item.name)
            cursor = targetIndex
            currentOffset = item.offset
        }
        result += draft[cursor...]
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), baseAttachments)
    }
}

extension DesktopTextProvider {
    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw DesktopRuntimeError.message("请先提供消息内容或附件。")
        }

        func convertAttachment(_ attachment: DesktopMessageAttachment) throws -> DesktopMessageContentPart {
            switch attachment.kind {
            case .image:
                guard let url = attachment.dataURL, !url.isEmpty else {
                    throw DesktopRuntimeError.message("图片附件缺少内容数据。")
                }
                return .image(DesktopMessageImage(url: url, name: attachment.name))
            case .text:
                let doc = "\n\n--- \(attachment.name) ---\n\(attachment.text ?? "")\n---\n"
                return .text(doc)
            case .inlineText:
                return .text(attachment.text ?? "")
            }
        }

        let nsText = text as NSString
        let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(attachment://([^)\s]+)\)"#)
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []

        var parts: [DesktopMessageContentPart] = []
        var consumedIndices = Set<Int>()

        if !matches.isEmpty {
            var cursor = 0
            for match in matches {
                let target = nsText.substring(with: match.range(at: 2))
                let index: Int? = {
                    if let idx = Int(target), attachments.indices.contains(idx) { return idx }
                    return attachments.firstIndex { $0.name == target }
                }()
                if let index {
                    if match.range.location > cursor {
                        let prefix = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                        if !prefix.isEmpty { parts.append(.text(prefix)) }
                    }
                    consumedIndices.insert(index)
                    parts.append(try convertAttachment(attachments[index]))
                    cursor = match.range.location + match.range.length
                }
            }
            if cursor < nsText.length {
                let tail = nsText.substring(from: cursor)
                if !tail.isEmpty { parts.append(.text(tail)) }
            }
        } else if !text.isEmpty {
            parts.append(.text(text))
        }

        for (index, attachment) in attachments.enumerated() where !consumedIndices.contains(index) {
            parts.append(try convertAttachment(attachment))
        }

        let joinedText = parts.compactMap { $0.kind == .text ? $0.text : nil }.joined()
        let images = parts.compactMap { $0.kind == .image ? $0.image : nil }
        return DesktopMessage(id: id, role: .user, text: joinedText, images: images, parts: parts)
    }
}
