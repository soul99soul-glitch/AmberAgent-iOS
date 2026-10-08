import Foundation
import Observation
@preconcurrency import Shared

struct IOSDeepReadTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String

    static let customPrefix = "custom:"
    static let magazine = IOSDeepReadTemplate(
        id: "compose_magazine",
        name: "默认杂志",
        description: "摘要、关键点、脉络和延伸阅读。"
    )
    static let editorial = IOSDeepReadTemplate(
        id: "editorial_slant",
        name: "斜切图文",
        description: "更有编辑判断的图文版式。"
    )
    static let analysis = IOSDeepReadTemplate(
        id: "ios_analysis",
        name: "分析",
        description: "旧 iOS 历史版式：突出判断、风险和下一步。"
    )
    static let reading = editorial
    static let builtIns = [magazine, editorial]
    static let defaultId = magazine.id

    static func template(id: String) -> IOSDeepReadTemplate {
        let normalized = normalizedTemplateId(id)
        if normalized.hasPrefix(customPrefix) {
            return IOSDeepReadTemplate(id: normalized, name: "自定义模板", description: "本机保存的 HTML 模板。")
        }
        return builtIns.first { $0.id == normalized } ?? {
            if id == "ios_analysis" { return analysis }
            return magazine
        }()
    }

    static func normalizedTemplateId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "", "ios_magazine":
            return magazine.id
        case "ios_reading":
            return editorial.id
        case "ios_analysis":
            return analysis.id
        default:
            if trimmed.hasPrefix(customPrefix) { return trimmed }
            if builtIns.contains(where: { $0.id == trimmed }) { return trimmed }
            // The standalone DeepRead app's own generation templates (not offered by Amber).
            if trimmed.hasPrefix("deepread_") { return trimmed }
            return magazine.id
        }
    }
}

struct IOSDeepReadCustomTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var html: String
    var createdByAI: Bool
    var createdAt: Int64
    var updatedAt: Int64

    init(
        id: String = IOSDeepReadTemplate.customPrefix + UUID().uuidString.lowercased(),
        name: String,
        description: String,
        html: String,
        createdByAI: Bool,
        createdAt: Int64 = IOSDeepReadClock.currentEpochMs(),
        updatedAt: Int64 = IOSDeepReadClock.currentEpochMs()
    ) {
        self.id = id.hasPrefix(IOSDeepReadTemplate.customPrefix) ? id : IOSDeepReadTemplate.customPrefix + id
        self.name = IOSDeepReadSourceNormalizer.clean(name).deepReadIfEmpty("自定义模板")
        self.description = IOSDeepReadSourceNormalizer.clean(description).deepReadPrefixString(240)
        self.html = html
        self.createdByAI = createdByAI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum IOSDeepReadTemplateStoreError: LocalizedError, Equatable {
    case invalidTemplate(String)
    case notFound
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidTemplate(let message): message
        case .notFound: "模板不存在。"
        case .persistenceFailed: "模板保存失败，请检查设备存储后重试。"
        }
    }
}

@MainActor
@Observable
final class IOSDeepReadTemplateStore {
    static let shared = IOSDeepReadTemplateStore()

    private(set) var templates: [IOSDeepReadCustomTemplate]
    private(set) var persistenceError: String?

    private let directory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = root.appendingPathComponent("deep_read", isDirectory: true)
        fileURL = directory.appendingPathComponent("templates.json", isDirectory: false)
        templates = Self.load(from: fileURL, decoder: decoder, fileManager: fileManager)
    }

    func template(id: String) -> IOSDeepReadCustomTemplate? {
        templates.first { $0.id == id }
    }

    @discardableResult
    func save(_ template: IOSDeepReadCustomTemplate) throws -> IOSDeepReadCustomTemplate {
        let validation = IOSDeepReadTemplateValidator.validateHTML(template.html)
        guard validation.ok else {
            throw IOSDeepReadTemplateStoreError.invalidTemplate(validation.error ?? "模板校验失败。")
        }
        var next = template
        next.id = IOSDeepReadTemplate.normalizedTemplateId(next.id)
        if !next.id.hasPrefix(IOSDeepReadTemplate.customPrefix) {
            next.id = IOSDeepReadTemplate.customPrefix + UUID().uuidString.lowercased()
        }
        next.updatedAt = IOSDeepReadClock.currentEpochMs()
        var proposed = templates
        if let index = proposed.firstIndex(where: { $0.id == next.id }) {
            proposed[index] = next
        } else {
            proposed.append(next)
        }
        proposed.sort { $0.updatedAt > $1.updatedAt }
        do {
            try persist(proposed)
        } catch {
            persistenceError = IOSDeepReadTemplateStoreError.persistenceFailed.localizedDescription
            throw IOSDeepReadTemplateStoreError.persistenceFailed
        }
        if templates != proposed { templates = proposed }
        persistenceError = nil
        return next
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let proposed = templates.filter { $0.id != id }
        do {
            try persist(proposed)
        } catch {
            persistenceError = IOSDeepReadTemplateStoreError.persistenceFailed.localizedDescription
            return false
        }
        if templates != proposed { templates = proposed }
        persistenceError = nil
        return true
    }

    private func persist(_ proposed: [IOSDeepReadCustomTemplate]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(proposed)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func load(from url: URL, decoder: JSONDecoder, fileManager: FileManager) -> [IOSDeepReadCustomTemplate] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([IOSDeepReadCustomTemplate].self, from: data) else {
            return []
        }
        return decoded.filter { IOSDeepReadTemplateValidator.validateHTML($0.html).ok }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

enum IOSDeepReadHTMLTemplateRenderer {
    static func render(task: IOSDeepReadTask, template: IOSDeepReadCustomTemplate, fontScale: Float, fontModeWireName: String) throws -> String {
        let validation = IOSDeepReadTemplateValidator.validateHTML(template.html)
        guard validation.ok else {
            throw IOSDeepReadTemplateStoreError.invalidTemplate(validation.error ?? "模板校验失败。")
        }
        let contentHTML = markdownToHTML(task.resultMarkdown.isEmpty ? IOSDeepReadDraftGenerator.generate(task: task) : task.resultMarkdown)
        let sourcesHTML = task.sources.map { source in
            let url = source.url.map { "<div class=\"source-url\">\(escapeHTML($0))</div>" } ?? ""
            return "<li><strong>\(escapeHTML(source.kind.localizedTitle))｜\(escapeHTML(source.title))</strong><p>\(escapeHTML(source.content.deepReadPrefixString(420)))</p>\(url)</li>"
        }.joined(separator: "\n")
        let replacements: [String: String] = [
            "{{title}}": escapeHTML(task.title),
            "{{summary}}": escapeHTML(summary(from: task.resultMarkdown)),
            "{{content_html}}": contentHTML,
            "{{analysis_html}}": contentHTML,
            "{{narrative_html}}": contentHTML,
            "{{extended_reading_html}}": "<ul class=\"sources\">\(sourcesHTML)</ul>",
            "{{sources_html}}": "<ul class=\"sources\">\(sourcesHTML)</ul>",
            "{{font_css}}": fontCSS(scale: fontScale, modeWireName: fontModeWireName)
        ]
        var html = template.html
        for (key, value) in replacements {
            html = html.replacingOccurrences(of: key, with: value)
        }
        return html
    }

    static func starterHTML(name: String = "自定义模板") -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        {{font_css}}
        body { margin: 0; padding: 24px; background: #f8fafc; color: #111827; }
        article { max-width: 760px; margin: 0 auto; }
        h1 { font-size: 30px; line-height: 1.18; margin: 0 0 14px; }
        .summary { color: #475569; margin-bottom: 20px; }
        section { background: #ffffff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 18px; margin: 14px 0; }
        .sources { padding-left: 18px; }
        .source-url { color: #2563eb; word-break: break-all; font-size: 12px; }
        @media screen and (prefers-color-scheme: dark) {
            body { background: #201c19; color: #f1e9df; }
            .summary { color: #b9aa98; }
            section { background: #2a2520; border-color: #54493d; }
            .source-url { color: #93c5fd; }
        }
        </style>
        </head>
        <body>
        <article>
        <h1>{{title}}</h1>
        <p class="summary">{{summary}}</p>
        <section>{{analysis_html}}</section>
        <section>{{extended_reading_html}}</section>
        </article>
        </body>
        </html>
        """
    }

    private static func fontCSS(scale: Float, modeWireName: String) -> String {
        let safeScale = max(0.7, min(1.8, Double(scale)))
        let family = modeWireName == "system"
            ? "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            : "Georgia, 'Times New Roman', 'Songti SC', serif"
        return """
        :root { font-size: \(String(format: "%.2f", safeScale * 16))px; }
        body { font-family: \(family); line-height: 1.72; }
        """
    }

    private static func summary(from markdown: String) -> String {
        let clean = IOSDeepReadSourceNormalizer.cleanMultiline(markdown)
        guard !clean.isEmpty else { return "暂无摘要。" }
        return clean
            .split(whereSeparator: \.isNewline)
            .first { line in
                !line.hasPrefix("#") && !String(line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { String($0).deepReadPrefixString(180) } ?? clean.deepReadPrefixString(180)
    }

    private static func markdownToHTML(_ markdown: String) -> String {
        var html: [String] = []
        var inList = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if inList {
                    html.append("</ul>")
                    inList = false
                }
                continue
            }
            if line.hasPrefix("### ") {
                if inList { html.append("</ul>"); inList = false }
                html.append("<h3>\(escapeHTML(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                if inList { html.append("</ul>"); inList = false }
                html.append("<h2>\(escapeHTML(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                if inList { html.append("</ul>"); inList = false }
                html.append("<h1>\(escapeHTML(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("- ") {
                if !inList {
                    html.append("<ul>")
                    inList = true
                }
                html.append("<li>\(escapeHTML(String(line.dropFirst(2))))</li>")
            } else {
                if inList { html.append("</ul>"); inList = false }
                html.append("<p>\(escapeHTML(line))</p>")
            }
        }
        if inList { html.append("</ul>") }
        return html.joined(separator: "\n")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum IOSDeepReadTemplateDraftGenerator {
    enum DraftError: LocalizedError, Equatable {
        case missingModel
        case emptyResponse
        case invalidJSON
        case invalidTemplate(String)

        var errorDescription: String? {
            switch self {
            case .missingModel: "没有可用模型，无法生成模板草稿。"
            case .emptyResponse: "模型没有返回模板草稿。"
            case .invalidJSON: "模型返回的模板草稿不是可解析 JSON。"
            case .invalidTemplate(let reason): "模板草稿未通过校验：\(reason)"
            }
        }
    }

    @MainActor
    static func generateDraft(
        name: String,
        brief: String,
        providerSetting: ProviderSetting,
        modelId: String,
        provider: IOSAgentTextProvider = OpenAIKmpProviderAdapter()
    ) async throws -> IOSDeepReadCustomTemplate {
        let safeModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeModel.isEmpty else { throw DraftError.missingModel }
        let prompt = """
        为 AmberAgent 深度阅读生成一个受限 HTML 模板，返回 JSON：{"name":"","description":"","html":""}。
        模板必须包含 <!DOCTYPE html> 或 <html>，不能包含 JavaScript、iframe、form、外部链接/外部资源、CSS url/import。
        必须至少使用这些占位符：{{title}}、{{summary}}、{{analysis_html}}、{{extended_reading_html}}、{{font_css}}。
        模板名称：\(name)
        用户要求：\(brief)
        """
        let messages = [
            UIMessage.companion.system(prompt: "你只输出 JSON，不输出 Markdown 代码围栏。"),
            UIMessage.companion.user(prompt: prompt)
        ]
        let params = TextGenerationParams(
            model: Model(modelId: safeModel, displayName: safeModel, id: KotlinUuid.companion.random(), type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [], abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil),
            temperature: nil,
            topP: nil,
            maxTokens: KotlinInt(value: 2_800),
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let chunk = try await provider.generateText(providerSetting: providerSetting, messages: messages, params: params)
        let text = (chunk.choices.first?.message?.parts ?? [])
            .compactMap { $0 as? UIMessagePart.Text }
            .map { $0.text }
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DraftError.emptyResponse }
        guard let data = extractJSONObject(from: text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DraftError.invalidJSON
        }
        let html = object["html"] as? String ?? ""
        let validation = IOSDeepReadTemplateValidator.validateHTML(html)
        guard validation.ok else { throw DraftError.invalidTemplate(validation.error ?? "未知错误") }
        return IOSDeepReadCustomTemplate(
            name: (object["name"] as? String)?.deepReadIfEmpty(name) ?? name,
            description: (object["description"] as? String) ?? brief,
            html: html,
            createdByAI: true
        )
    }

    private static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return trimmed }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[start...end])
    }
}
