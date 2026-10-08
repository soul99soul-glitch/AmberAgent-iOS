import Foundation
@preconcurrency import Shared

/// A batched title-translation step the dashboard store can run on fetch. Takes
/// the raw titles, returns a `[originalTitle: chineseTitle]` map for those it
/// translated (others absent → caller keeps the original). Injected by the view
/// layer so the persistence store stays LLM-free and unit-testable.
typealias IOSHotListTitleTranslate = (_ titles: [String]) async -> [String: String]

/// Translates non-Chinese hot-list / ranking titles into fluent Simplified
/// Chinese on fetch (technical terms preserved), gated by the board's
/// `hotListTranslateToChinese` toggle. One batched LLM call per refresh keeps
/// cost bounded; already-Chinese titles are skipped, and any failure degrades
/// silently to the raw title (no fabricated translation).
enum IOSHotListTitleTranslator {
    /// A title needs translation only when it contains NO CJK ideograph. Mixed
    /// titles like "OpenAI 发布 GPT-5" already read in Chinese and are left as-is;
    /// only zero-ideograph titles ("Apple unveils new chip") are translated.
    static func needsTranslation(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        for scalar in trimmed.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value)      // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value)  // CJK Ext-A
                || (0xF900...0xFAFF).contains(scalar.value) { // CJK Compatibility
                return false
            }
        }
        return true
    }

    /// Returns a `[originalTitle: chineseTitle]` map for the titles that were
    /// translated. Already-Chinese titles and any the model omits are absent.
    /// Never throws — an LLM failure yields an empty map (honest degradation).
    static func translate(
        titles: [String],
        providerSetting: ProviderSetting,
        modelId: String,
        provider: IOSAgentTextProvider = OpenAIKmpProviderAdapter()
    ) async -> [String: String] {
        let pending = Array(Set(titles.filter(needsTranslation))).prefix(60).map { $0 }
#if DEBUG
        NSLog("[AmberTranslate] translate() in=\(titles.count) pending=\(pending.count) model=\(modelId)")
#endif
        guard !pending.isEmpty else { return [:] }
        let numbered = pending.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let system = "你是专业的中文科技编辑。把给定的非中文榜单标题翻译成通顺、简洁的简体中文标题；专有名词、产品名、公司名、技术术语（如 OpenAI、GPT-5、Kubernetes）保留原文，不要音译。只输出 JSON。"
        let userPrompt = """
        把下面每条标题翻译成简体中文。保持序号一一对应，不要增删条目。
        输出严格 JSON 对象：{"items":[{"i":序号,"zh":"中文标题"}]}，不要代码围栏、不要解释。

        \(numbered)
        """
        let messages = [
            UIMessage.companion.system(prompt: system),
            UIMessage.companion.user(prompt: userPrompt)
        ]
        let params = TextGenerationParams(
            model: Model(modelId: modelId, displayName: modelId, id: KotlinUuid.companion.random(), type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [], abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil),
            temperature: nil,
            topP: nil,
            maxTokens: KotlinInt(value: 4_000),
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let text: String
        do {
            let chunk = try await provider.generateText(providerSetting: providerSetting, messages: messages, params: params)
            text = (chunk.choices.first?.message?.parts ?? [])
                .compactMap { $0 as? UIMessagePart.Text }
                .map { $0.text }
                .joined(separator: "")
        } catch {
#if DEBUG
            NSLog("[AmberTranslate] generateText threw: \(error)")
#endif
            return [:]
        }
        let result = parse(text, pending: pending)
#if DEBUG
        NSLog("[AmberTranslate] llm chars=\(text.count) parsed=\(result.count) head=\(text.prefix(120))")
#endif
        return result
    }

    /// Parses `{"items":[{"i":N,"zh":"..."}]}` into `[original: translation]`,
    /// mapping the 1-based index back to `pending`. Tolerates ```json fences and
    /// surrounding prose (reuses the deep-read JSON-object extractor).
    static func parse(_ text: String, pending: [String]) -> [String: String] {
        guard let json = IOSDeepReadDraftGenerator.extractJSONObject(text),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: String] = [:]
        for entry in items {
            guard let zhRaw = entry["zh"] as? String else { continue }
            let zh = zhRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !zh.isEmpty else { continue }
            let idx: Int?
            if let i = entry["i"] as? Int { idx = i }
            else if let s = entry["i"] as? String { idx = Int(s) }
            else { idx = nil }
            guard let i = idx, i >= 1, i <= pending.count else { continue }
            result[pending[i - 1]] = zh
        }
        return result
    }
}

