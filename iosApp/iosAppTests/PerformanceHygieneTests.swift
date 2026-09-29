import XCTest

/// 锁住 2026-09-29 性能排查（见 `docs/reviews/2026-09-29-ios-performance-program.md`）修复的具体失效点，
/// 防止 SwiftUI 失效放大、主线程阻塞类问题回归。沿用 `IOSSettingsWiringTests` 的读源码断言风格：
/// 不跑 UI，只断言修复后的代码形态仍在，避免同类问题在不被察觉的情况下悄悄重新引入。
final class PerformanceHygieneTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosAppRoot = testsDir.deletingLastPathComponent()
        let fileURL = iosAppRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 提取从 `startMarker` 所在行到其后第一个满足 `endMarker` 的行（不含）之间的片段，
    /// 用于把断言限定在具体的属性/方法体内，而不是整份文件。
    private func slice(of content: String, from startMarker: String, untilLineContaining endMarker: String) throws -> String {
        let lines = content.components(separatedBy: "\n")
        guard let startIndex = lines.firstIndex(where: { $0.contains(startMarker) }) else {
            XCTFail("未找到起始标记 \(startMarker)，源码结构可能已变化，需要更新测试定位。")
            return ""
        }
        let tailLines = lines[(startIndex + 1)...]
        let endOffset = tailLines.firstIndex(where: { $0.contains(endMarker) }) ?? lines.endIndex
        return lines[startIndex..<endOffset].joined(separator: "\n")
    }

    // MARK: - MessageBubbleView：环境注入必须可判等/身份稳定

    /// 曾经每次 body 求值都向 `.environment` 注入新建闭包（不可判等），导致所有可见消息的
    /// Markdown 与代码块随气泡重算而整体失效重建。现改为注入可判等的 messageID 与身份稳定的
    /// 静态 provider，这里锁住两处都没有退回闭包字面量。
    func testMessageBubbleViewInjectsIdentityStableEnvironmentValues() throws {
        let content = try source("iosApp/MessageBubbleView.swift")

        XCTAssertFalse(
            content.contains(".environment(\\.chatArtifactCodeBlockPinAction"),
            "chatArtifactCodeBlockPinAction 曾每次 body 求值注入新建闭包，不可判等会让所有消息 Markdown 重建；应改注入可判等的 chatArtifactMessageID。"
        )
        XCTAssertTrue(
            content.contains("\\.swiftStreamingMarkdownCodeBlockHeaderAccessory"),
            "未找到 swiftStreamingMarkdownCodeBlockHeaderAccessory 环境键注入，流式代码块头部收纳入口可能被移除或改名。"
        )
        for file in ["iosApp/MessageBubbleView.swift", "iosApp/ChatSubAgentResultCard.swift"] {
            XCTAssertTrue(
                try source(file).contains(".environment(\\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)"),
                "\(file) 的 openURL 必须注入常量 ChatMarkdownOpenURLPolicy.openURLAction；每次新建的 OpenURLAction 不可判等，会让子树链接文本随重算失效。"
            )
        }
        XCTAssertTrue(
            content.contains("ChatCodeBlockHeaderAccessory.streamingHeaderProvider"),
            "swiftStreamingMarkdownCodeBlockHeaderAccessory 必须注入身份稳定的静态 provider（ChatCodeBlockHeaderAccessory.streamingHeaderProvider），退回闭包字面量会让代码块头部每次都判定环境变化。"
        )
    }

    // MARK: - ConversationActivityCenter：被观察的 notices 只整体发布

    /// 曾经对被 @Observable 观察的 `notices` 原地 `removeAll`/增删，哪怕结果无变化也会通知观察者，
    /// 导致聊天页整页重算。现在所有增删都在不受观察的 `workingNotices` 工作副本上进行，只有内容
    /// 真正变化时才整体写回 `notices`。锁住文件里不再出现裸的 `notices.`（`workingNotices.` 不受影响，
    /// 因为其中紧跟 `notices` 的是大写 N，不匹配小写字面量）。
    func testConversationActivityCenterNoticesOnlyMutatedAsWorkingCopy() throws {
        let code = try source("iosApp/ConversationActivityCenter.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(
            code.contains("notices."),
            "notices 是被 @Observable 观察的属性，分步增删必须经 workingNotices 工作副本再整体发布；直接出现 notices. 说明有代码在原地修改被观察属性，会在无实际变化时也触发聊天页整页重算。"
        )
    }

    // MARK: - CouncilChatRuntimeView：首页 body 路径不读盘解码整份存档

    /// 曾经首页 `homeResumeContext` 在 body 读取路径里 `archiveStore.load(taskId:)`，读盘并解码整份
    /// 存档只为判断“是否存在可续任务”。现改为 `archiveStore.exists(taskId:)`。其余方法（如恢复中断任务）
    /// 仍然需要真正 load，因此断言限定在 homeResumeContext 这个计算属性片段内。
    func testHomeResumeContextDoesNotLoadFullArchive() throws {
        let content = try source("iosApp/CouncilChatRuntimeView.swift")
        let body = try slice(
            of: content,
            from: "var homeResumeContext: CouncilHomeResumeContext?",
            untilLineContaining: "func recoverInterruptedTasks"
        )

        XCTAssertTrue(
            body.contains("archiveStore.exists(taskId:"),
            "homeResumeContext 应通过 archiveStore.exists(taskId:) 判断是否有可续任务，不读盘解码。"
        )
        XCTAssertFalse(
            body.contains("archiveStore.load("),
            "homeResumeContext 在首页 body 读取路径里调用 archiveStore.load 会读盘并解码整份存档，只为判断是否存在就付出全量反序列化代价。"
        )
    }

    // MARK: - ChatView：顶栏摘要判据不读原始 messages 集合

    /// 曾经聊天顶栏在 body 读取路径里直接读 `viewModel.messages`（流式高频变化的原始集合）计算回顾
    /// 状态，现改为读取可判等的 `ChatListSummarySnapshot` 投影（`chatListSummary`）。`topBar` 里仍有
    /// `onLocateSnippet`/`onLocateArtifact` 等点击闭包读取 viewModel.messages，那是事件路径、不受 body
    /// 重算频率约束，因此断言只限定在 recapEligible/recapStale 两个实参片段内。
    func testTopBarRecapArgumentsDoNotReadRawMessages() throws {
        let content = try source("iosApp/ChatView.swift")

        guard let eligibleRange = content.range(of: "recapEligible:") else {
            XCTFail("未找到 recapEligible: 实参，ChatTopBarView 调用点结构可能已变化。")
            return
        }
        let eligibleLineEnd = content[eligibleRange.upperBound...].firstIndex(of: "\n") ?? content.endIndex
        let eligibleArgument = content[eligibleRange.upperBound..<eligibleLineEnd]
        XCTAssertFalse(
            eligibleArgument.contains("viewModel.messages"),
            "recapEligible 曾直接读 viewModel.messages 判定是否可回顾，应改读 chatListSummary 投影，否则顶栏会随每次流式增量重算。"
        )

        guard let staleRange = content.range(of: "recapStale:") else {
            XCTFail("未找到 recapStale: 实参，ChatTopBarView 调用点结构可能已变化。")
            return
        }
        let staleTailStart = staleRange.upperBound
        let staleClosureEnd = content[staleTailStart...].range(of: "} ?? false,")?.upperBound ?? content.endIndex
        let staleArgument = content[staleTailStart..<staleClosureEnd]
        XCTAssertFalse(
            staleArgument.contains("viewModel.messages"),
            "recapStale 曾直接读 viewModel.messages 判定回顾是否过期，应改读 chatListSummary 的 messageIDs/lastMessageID 投影，否则顶栏会随每次流式增量重算。"
        )
    }

    // MARK: - ChatViewModel：工具可用性判断不探测系统权限

    /// 工具是否暴露只取决于用户设置的能力策略（permissionPolicy(capabilityId:)），不得调用
    /// permissionsStatus() 逐个探测系统权限——那是同步系统查询，曾出现在发送路径上阻塞主线程。
    /// 注释里提及 permissionsStatus() 作为反面说明是允许的，这里只检查非注释代码行里没有真实调用。
    func testChatViewModelDoesNotProbeSystemPermissionsForToolAvailability() throws {
        let content = try source("iosApp/ChatViewModel.swift")
        let codeLines = content
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        let offendingLines = codeLines.filter { $0.contains("permissionsStatus()") }
        XCTAssertTrue(
            offendingLines.isEmpty,
            "工具可用性判断不得调用 permissionsStatus() 逐个探测系统权限（应使用 permissionPolicy(capabilityId:)），命中行：\(offendingLines)"
        )
    }

    // MARK: - MarkdownView：AmberTableLayout 必须自定义 updateCache

    /// SwiftUI 的 Layout 协议默认 updateCache 会在每次布局都重新调用 makeCache 整表重测。
    /// AmberTableLayout 按内容指纹 + 子视图数量复用缓存，这里锁住 updateCache 仍被显式实现。
    func testAmberTableLayoutImplementsUpdateCache() throws {
        let layout = try slice(
            of: try source("iosApp/MarkdownView.swift"),
            from: "struct AmberTableLayout: Layout",
            untilLineContaining: "struct AmberMarkdownView"
        )

        XCTAssertTrue(
            layout.contains("func updateCache("),
            "AmberTableLayout 必须实现 updateCache，否则 SwiftUI 默认实现会在每次布局都重新调用 makeCache，导致历史区任意一行动画都触发所有表格整表重测。"
        )
    }
}
