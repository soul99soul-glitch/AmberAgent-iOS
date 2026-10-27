import Foundation

final class DesktopMemoryCredentials: DesktopCredentialStore {
    var values: [UUID: String] = [:]
    func load(id: UUID) throws -> String { values[id] ?? "" }
    func save(_ value: String, id: UUID) throws { values[id] = value }
    func delete(id: UUID) throws { values[id] = nil }
}

#if DEBUG || AMBER_MAC_PREVIEW
@MainActor extension DesktopWorkspace {
    static func uiFixture() -> DesktopWorkspace {
        let defaults = UserDefaults(suiteName: "app.amber.macos.ui-fixture")!
        defaults.removePersistentDomain(forName: "app.amber.macos.ui-fixture")
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        if let initial = settings.selectedProvider {
            var config = initial
            config.name = "桌面验收 · 长模型名称不会挤压工具栏"
            config.modelID = "amber-layout-fixture"
            try? settings.saveProvider(config, apiKey: "fixture-only")
        }
        let conversation = DesktopConversation(title: "将想法变成清晰、可执行的下一步", messages: [
            DesktopMessage(role: .user, text: "帮我梳理桌面版的工作方式，给出一份简洁的计划。"),
            DesktopMessage(role: .assistant, text: """
            ## 让专注，从这里开始

            你可以在左侧管理对话，在主工作区延续思考。**配置、消息与历史记录**都有明确的归属，切换会话后仍会保存到原来的位置。

            | 工作方式 | 对应操作 |
            | --- | --- |
            | 开始新的思考 | 新建对话 ⌘N |
            | 回到已有内容 | 搜索会话 ⌘F |
            | 保留阶段成果 | 导出会话 |

            ```swift
            let nextStep = "先完成一件重要的事"
            print(nextStep)
            ```

            这是一段用于检查换行、边距和正文宽度的长文本。缩窄窗口时，段落应该自然换行；加宽窗口后，阅读区仍保持舒适的行长。代码、列表和表格应有明确层次，输入框与正文对齐。
            """, reasoning: "先确认目标，再按依赖关系组织步骤，最后检查每个操作能否到达可验证的结果。"),
        ], isPinned: true)
        let interrupted = DesktopConversation(title: "中断后可以继续的工作", messages: [
            DesktopMessage(role: .user, text: "继续整理刚才的内容。"),
            DesktopMessage(role: .assistant, text: "已经保留收到的内容。", state: .cancelled),
        ])
        let structured = DesktopConversation(title: "结构化内容显示 · 本地示例", messages: [
            DesktopMessage(role: .system, text: "这是一条用于检查消息身份的系统示例。"),
            DesktopMessage(role: .user, text: "查看附件与工具消息的显示边界。"),
            DesktopMessage(role: .assistant, text: "这是附件显示提示的本地示例。", unsupportedPartCount: 3),
            DesktopMessage(role: .tool, text: "本地示例输出，用于检查工具身份；本次没有执行工具。"),
        ])
        let reading = DesktopConversation(title: "阅读排版 · 本地示例", messages: [DesktopMessage(role: .assistant, text: """
        ## 阅读排版

        3. **第一项**
        4. 第二项
          - 嵌套要点

        > 引用说明
        >
        > > 更深引用

        左 | 中 | 右
        :--- | :---: | ---:
        **重点** | [来源](https://example.com) | 123
        这是一段较长的中文内容，用来验证同一行表格单元格换行后边框高度与邻列保持一致。 | `let value = 1` | 999

        ```swift
        let longLine = "这是一条不应自动折行的长代码：abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789"
        let mathSource = "$E=mc^2$" // 代码中的公式分隔符保持原文
        ```

        ### 数学公式

        内联公式 $E=mc^2$ 与 \\(\\frac{a}{b}\\)；代码 `$x$` 和价格 $100 and $200 保持原文。

        $$
        \\frac{a+b}{c} + \\sqrt{x^2+y^2}
        $$

        \\[
        \\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}
        \\]
        """)])
        let context = DesktopConversation(title: "上下文整理 · 本地示例", messages: (0..<4).flatMap { index in
            [DesktopMessage(role: .user, text: "本地示例问题 \(index + 1)"),
             DesktopMessage(role: .assistant, text: index < 2
                ? String(repeating: "这是用于检查上下文整理的本地工作记录，保留原始历史可以回看全部决定。", count: 30)
                : "这是最近的本地示例回答 \(index + 1)。")]
        })
        let values = [conversation, interrupted, DesktopConversation(title: "这是一条很长很长的会话标题，用于检查侧栏截断与完整提示"), structured, reading, context]
        return DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage(values),
            provider: DesktopFixtureProvider(), initialConversations: values,
            agentTasks: DesktopAgentTasks(defaults: defaults))
    }
}

@MainActor private final class DesktopFixtureProvider: DesktopTextProvider {
    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        let generation = DesktopGeneration()
        let task = Task {
            let parts = [
                "这是界面预览示例，未向真实模型发送请求。",
                "你可以在生成时切换会话，",
                "再通过输入区的入口回到原会话。",
                "停止后已收到的示例内容会保留。",
                "也可以继续体验复制、附件和窗口布局。",
            ]
            var text = ""
            do {
                for part in parts {
                    try Task.checkCancellation()
                    text += part
                    generation.yield(.snapshot(text: text, reasoning: ""))
                    try await Task.sleep(for: .seconds(6))
                }
                generation.yield(.complete)
            } catch is CancellationError {
                // DesktopGeneration.cancel already owns and publishes the terminal state.
            } catch {
                generation.yield(.failed("本地预览示例中断，请重新生成。"))
            }
        }
        generation.installCancellation { task.cancel() }
        return generation
    }
}
#endif
