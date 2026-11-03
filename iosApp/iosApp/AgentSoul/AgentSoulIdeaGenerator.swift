import Foundation
@preconcurrency import Shared

/// 「灵感」点子生成器：把 Soul + 记忆 + 日程 汇成一次模型调用，产出 3–4 张卡片。
///
/// 刻意做得很薄：不引入新 provider 抽象，直接复用既有
/// `IOSAgentTextProvider` 与 `ChatViewModel.makeAuxiliaryTextGenerationParams`，
/// 与「建议/标题」走的完全同一条辅助模型路径。
@MainActor
enum AgentSoulIdeaGenerator {
    /// 返回 nil 表示无法生成（未配置模型 / 网络失败 / 解析不出），调用方保留旧缓存。
    static func generate(context: String) async -> [AgentSoulIdea]? {
        let settings = IOSSharedSettingsStore()
        let snapshot = settings.snapshot
        guard let model = snapshot.getCurrentChatModel(),
              let provider = ChatProviderConfiguration.provider(
                for: model,
                providers: snapshot.providers
              ),
              ChatProviderConfiguration.issue(for: model, provider: provider) == nil else {
            return nil
        }

        let assistant = snapshot.getCurrentAssistant()
        let params = ChatViewModel.makeAuxiliaryTextGenerationParams(
            model: model,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: nil
            ),
            assistantBodies: assistant.customBodies
        )

        let prompt = buildPrompt(context: context)
        let textProvider = OpenAIKmpProviderAdapter()
        do {
            let chunk = try await textProvider.generateText(
                providerSetting: provider,
                messages: [UIMessage.companion.user(prompt: prompt)],
                params: params
            )
            guard let raw = chunk.choices.first?.message?.toText() else { return nil }
            return parse(raw)
        } catch {
            return nil
        }
    }

    private static func buildPrompt(context: String) -> String {
        """
        你在帮用户想「现在可以聊什么」。根据下面这些背景，给出 3 到 4 个具体、
        当下就能开聊的点子。

        \(context.isEmpty ? "（暂无额外背景）" : context)

        要求：
        - 每个点子必须结合上面某个具体背景，不要泛泛而谈。
        - title 是一句自然的话，像朋友开口那样，不超过 18 个字。
        - reason 用半句说明为什么现在聊这个，不超过 20 个字。
        - prompt 是点进对话后要直接发送的第一句话，要能独立成立。
        - 只输出 JSON 数组，不要任何解释文字或代码围栏。

        格式：[{"title":"...","reason":"...","prompt":"..."}]
        """
    }

    private static func parse(_ raw: String) -> [AgentSoulIdea]? {
        // 容忍模型偶尔包一层 ```json 或前后带解释。
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { return nil }

        struct Payload: Decodable {
            let title: String
            let reason: String?
            let prompt: String
        }
        guard let payloads = try? JSONDecoder().decode([Payload].self, from: data) else { return nil }

        let ideas = payloads
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(4)
            .map { payload in
                AgentSoulIdea(
                    title: payload.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    reason: payload.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    prompt: payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        return ideas.isEmpty ? nil : Array(ideas)
    }
}
