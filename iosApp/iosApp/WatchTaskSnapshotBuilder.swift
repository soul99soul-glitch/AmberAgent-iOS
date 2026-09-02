import Foundation

enum WatchTaskSnapshotBuilder {
    static func idle(
        languageCode: String? = nil,
        now: Date = Date()
    ) -> WatchTaskSnapshot {
        var snapshot = WatchTaskSnapshot.idle
        snapshot.languageCode = languageCode
        snapshot.updatedAt = now
        return snapshot
    }

    static func make(
        runId: String,
        conversationId: String?,
        presentation: AgentActivityPresentation,
        summary: String? = nil,
        decision: WatchDecision? = nil,
        languageCode: String? = nil,
        now: Date = Date()
    ) -> WatchTaskSnapshot {
        let phase = presentation.phase.rawValue
        let stage = presentation.stage.rawValue
        let kind = presentation.kind.rawValue
        let headline = presentation.kind.localizedTitle(languageCode: languageCode)
        let detail = presentation.stage.localizedTitle(languageCode: languageCode)
        let metricText = presentation.metric.localizedShortText(languageCode: languageCode)
        let clippedSummary = WatchTaskText.clipped(summary, maxLength: 280)
        var visibleDecision = decision
        if conversationId == nil {
            visibleDecision?.options.removeAll { $0.style == .openOnPhone }
        }

        var actions: [WatchAction] = []
        if let decision = visibleDecision {
            switch decision.type {
            case .approval:
                actions.append(contentsOf: [.approve, .deny])
            case .askUser:
                actions.append(contentsOf: [.choose, .dictate])
            case .voiceReply:
                actions.append(.dictate)
            }
        }
        if presentation.phase == .running
            || presentation.phase == .waitingForUser
            || presentation.phase == .reconnecting {
            actions.append(.cancel)
        }
        if presentation.phase == .failed,
           presentation.retryable == true,
           conversationId != nil {
            actions.append(.retry)
        }
        // A decision card already owns its single open-on-phone affordance.
        // For ordinary states, keep the state-changing primary action first.
        if conversationId != nil, visibleDecision == nil {
            actions.append(.openOnPhone)
        }

        var seen = Set<WatchAction>()
        actions = actions.filter { seen.insert($0).inserted }

        return WatchTaskSnapshot(
            runId: runId,
            languageCode: languageCode,
            conversationId: conversationId,
            kind: kind,
            phase: phase,
            stage: stage,
            headline: headline,
            detail: WatchTaskText.singleLine(detail, maxLength: 80),
            summary: clippedSummary,
            metricText: metricText,
            decision: visibleDecision,
            actions: actions,
            updatedAt: now,
            isStale: false
        )
    }

    static func decision(
        from prompt: ChatToolApprovalPrompt,
        languageCode: String? = nil
    ) -> WatchDecision {
        switch prompt {
        case .memory(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: request.contentPreview,
                    fallback: request.reason,
                    chips: [request.action, request.scope, request.kind].compactMap { $0 },
                    languageCode: languageCode
                ),
                risk: .medium,
                languageCode: languageCode
            )
        case .search(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: request.target,
                    fallback: request.reason,
                    chips: [request.providerName],
                    languageCode: languageCode
                ),
                risk: .medium,
                languageCode: languageCode
            )
        case .webMount(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: "\(request.siteName) · \(request.host)",
                    fallback: request.reason,
                    chips: [request.toolName],
                    languageCode: languageCode
                ),
                risk: .high,
                languageCode: languageCode
            )
        case .workspace(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: request.target,
                    fallback: request.reason,
                    chips: [request.action, request.toolName],
                    languageCode: languageCode
                ),
                risk: request.isWrite ? .high : .medium,
                languageCode: languageCode
            )
        case .ish(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: request.commandPreview,
                    fallback: request.reason,
                    chips: [request.mode.rawValue, request.filename],
                    languageCode: languageCode
                ),
                risk: .high,
                languageCode: languageCode
            )
        case .mcp(let request):
            let decisionBody: String
            if let preview = request.skillImportPreview {
                decisionBody = skillImportBody(preview, languageCode: languageCode)
            } else if let preview = request.soulImportPreview {
                decisionBody = body(
                    primary: "\(String(preview.baseHash.prefix(10))) → \(String(preview.candidateHash.prefix(10)))",
                    fallback: preview.afterSummary,
                    chips: ["SOUL.md", "\(preview.changedLineCount) 行"],
                    languageCode: languageCode
                )
            } else if let preview = request.mcpImportPreview {
                decisionBody = body(
                    primary: "\(preview.skillName) · \(preview.servers.count) 个服务",
                    fallback: preview.servers.map(\.name).joined(separator: "、"),
                    chips: preview.servers.prefix(3).map(\.name),
                    languageCode: languageCode
                )
            } else {
                decisionBody = body(
                    primary: "\(request.serverName).\(request.toolName)",
                    fallback: request.reason,
                    chips: [WatchTaskText.singleLine(request.argumentsPreview, maxLength: 80)].compactMap { $0 },
                    languageCode: languageCode
                )
            }
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: decisionBody,
                risk: .high,
                languageCode: languageCode
            )
        case .council(let request):
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: body(
                    primary: request.objectivePreview,
                    fallback: request.reason,
                    chips: request.maxSeats.map {
                        [localized("席位", languageCode: languageCode) + " \($0)"]
                    } ?? [],
                    languageCode: languageCode
                ),
                risk: .medium,
                languageCode: languageCode
            )
        case .askUser(let request):
            return askUserDecision(
                from: WatchAskUserRequest(
                    id: request.id,
                    question: request.question,
                    options: request.options
                ),
                languageCode: languageCode
            )
        case .recipe(let request):
            // Wave B2: recipe 审批（mutation step / recipe_import）。
            let decisionBody: String
            switch request.payload {
            case .step(let payload):
                decisionBody = body(
                    primary: "\(localized("步骤", languageCode: languageCode)) \(payload.stepId) → \(payload.tool)",
                    fallback: request.reason,
                    chips: [request.recipeName, "v\(request.recipeVersion)"],
                    languageCode: languageCode
                )
            case .pluginInvocation(let payload):
                decisionBody = body(
                    primary: payload.toolId,
                    fallback: request.reason,
                    chips: [request.recipeName, "v\(request.recipeVersion)", payload.handler],
                    languageCode: languageCode
                )
            case .recipeImport(let payload):
                decisionBody = body(
                    primary: payload.description,
                    fallback: request.reason,
                    chips: [
                        request.recipeName,
                        "v\(request.recipeVersion)",
                        payload.mutationKind == .new
                            ? localized("新建", languageCode: languageCode)
                            : localized("更新", languageCode: languageCode),
                    ],
                    languageCode: languageCode
                )
            }
            return approvalDecision(
                id: request.id,
                title: request.title,
                body: decisionBody,
                risk: .high,
                languageCode: languageCode
            )
        }
    }

    static func askUserDecision(
        from request: WatchAskUserRequest,
        languageCode: String? = nil
    ) -> WatchDecision {
        // Match schema maxItems=6; keep free-text/dictate for anything beyond.
        let options = request.options.prefix(6).enumerated().map { index, title in
            WatchDecisionOption(
                id: "choice-\(index)",
                title: WatchTaskText.singleLine(title, maxLength: 28)
                    ?? localized("选项", languageCode: languageCode) + " \(index + 1)",
                style: .choice
            )
        }
        var allOptions = Array(options)
        allOptions.append(
            WatchDecisionOption(
                id: "skip",
                title: localized("跳过", languageCode: languageCode),
                style: .deny
            )
        )
        allOptions.append(
            WatchDecisionOption(
                id: "dictate",
                title: localized("语音回答", languageCode: languageCode),
                style: .dictate
            )
        )
        allOptions.append(
            WatchDecisionOption(
                id: "open-phone",
                title: localized("在 iPhone 回答", languageCode: languageCode),
                style: .openOnPhone
            )
        )

        return WatchDecision(
            id: request.id,
            type: options.isEmpty ? .voiceReply : .askUser,
            title: localized("需要你的回答", languageCode: languageCode),
            body: WatchTaskText.clipped(request.question, maxLength: 160)
                ?? localized("模型正在等待你的回答。", languageCode: languageCode),
            options: allOptions,
            riskLevel: .low,
            allowsVoice: true
        )
    }

    private static func approvalDecision(
        id: String,
        title: String,
        body: String,
        risk: WatchRiskLevel,
        languageCode: String?
    ) -> WatchDecision {
        WatchDecision(
            id: id,
            type: .approval,
            title: WatchTaskText.singleLine(
                localizedApprovalTitle(title, languageCode: languageCode),
                maxLength: 40
            )
                ?? localized("等待确认", languageCode: languageCode),
            body: body,
            options: [
                WatchDecisionOption(
                    id: "deny",
                    title: localized("拒绝", languageCode: languageCode),
                    style: .deny
                ),
                WatchDecisionOption(
                    id: "approve",
                    title: localized("允许", languageCode: languageCode),
                    style: .approve
                ),
                WatchDecisionOption(
                    id: "open-phone",
                    title: localized("在 iPhone 查看", languageCode: languageCode),
                    style: .openOnPhone
                )
            ],
            riskLevel: risk,
            allowsVoice: false
        )
    }

    private static func localizedApprovalTitle(_ title: String, languageCode: String?) -> String {
        switch title {
        case "保存记忆", "更新记忆", "删除记忆", "修改记忆",
             "在本地 WebMount 完成后继续", "清除 WebMount Session", "执行 WebMount 前台动作",
             "修改 Workspace", "读取 Workspace", "读取网页", "执行网络搜索",
             "交接到 iSH", "执行内置 iSH", "执行 Remote SSH",
             "启动 Remote SSH 作业", "停止 Remote SSH 作业",
             "启动内置 iSH 作业", "停止内置 iSH 作业",
             "更新核心指令", "导入技能", "导入 MCP", "试穿主题", "确认扩展操作",
             "执行 MCP 工具", "启动模型议会", "调度子代理", "执行 Recipe 步骤", "导入 Recipe":
            return localized(title, languageCode: languageCode)
        default:
            return title
        }
    }

    private static func body(
        primary: String?,
        fallback: String,
        chips: [String],
        languageCode: String?
    ) -> String {
        let primaryLine = WatchTaskText.singleLine(primary, maxLength: 120)
        let fallbackLine = WatchTaskText.singleLine(fallback, maxLength: 120)
        let chipLine = WatchTaskText.singleLine(
            chips
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            maxLength: 80
        )
        return [primaryLine, chipLine, fallbackLine]
            .compactMap { $0 }
            .first ?? localized("需要你在手表上确认这一步。", languageCode: languageCode)
    }

    private static func skillImportBody(
        _ preview: McpSkillImportPreview,
        languageCode: String?
    ) -> String {
        let action = preview.mutationKind == .new
            ? localized("新建", languageCode: languageCode)
            : localized("更新", languageCode: languageCode)
        let skillName = WatchTaskText.singleLine(preview.skillName, maxLength: 28)
            ?? localized("未命名 Skill", languageCode: languageCode)
        let baseHash = preview.baseHash.map { String($0.prefix(8)) }
            ?? localized("无", languageCode: languageCode)
        let candidateHash = String(preview.candidateHash.prefix(8))
        let changedFiles = localized(
            "文件变更（%lld 个文件）",
            defaultValue: "\(preview.changedFiles.count) 处变更",
            languageCode: languageCode,
            arguments: [Int64(preview.changedFiles.count)]
        )
        return "\(action) \(skillName) · \(changedFiles) · \(baseHash)→\(candidateHash)"
    }

    private static func localized(
        _ key: String,
        defaultValue: String? = nil,
        languageCode: String?,
        arguments: [CVarArg] = []
    ) -> String {
        guard let languageCode else { return defaultValue ?? key }
        if arguments.isEmpty {
            return WatchTaskLocalization.string(
                key,
                defaultValue: defaultValue ?? key,
                languageCode: languageCode
            )
        }
        return WatchTaskLocalization.formatted(
            key,
            defaultValue: defaultValue ?? key,
            arguments: arguments,
            languageCode: languageCode
        )
    }
}

struct WatchAskUserRequest: Equatable, Sendable {
    let id: String
    let question: String
    let options: [String]
}
