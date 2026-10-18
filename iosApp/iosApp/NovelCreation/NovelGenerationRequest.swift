import Foundation
@preconcurrency import Shared

extension DefaultNovelCreation {
    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        do {
            return try await modelRunner.resolveModel(for: policy)
        } catch let error as NovelError {
            throw error
        } catch let failure as NovelModelFailure {
            throw NovelError.modelUnavailable(failure.message)
        } catch {
            throw NovelError.modelUnavailable(error.localizedDescription)
        }
    }

    func promptKind(for request: NovelRunRequest) -> NovelPromptKind {
        switch request.kind {
        case .quickStart: .quickStart
        case .characterProposal: .characterProposal
        case .discussion: .discussion
        case .prose:
            request.granularity == .continuation ? .proseContinuation : .proseWholeChapter
        case .polish: .wholeChapterPolish
        case .regenerate: .wholeChapterRegeneration
        }
    }

    func modelPurpose(for request: NovelRunRequest) -> NovelModelPurpose {
        switch request.kind {
        case .quickStart: .quickStart
        case .characterProposal: .characterProposal
        case .discussion: .discussion
        case .prose, .regenerate: .prose
        case .polish: .polish
        }
    }

    /// 2026-07-26 用户明确裁决:四类生成任务一律不人为设置输出上限,思考等级一律 `.automatic`。
    ///
    /// 原实现按任务分配 2K/4K/8K 上限并对 prose/polish 关闭思考。真机取证(deepseek-v4-pro,
    /// 推理模型)显示 quickStart 的 2048 上限会被思考 token 吃掉,结构化建议还没写完就
    /// 触发 `finishReason == "length"`,整轮以「模型回复达到输出上限」硬失败——人为上限
    /// 制造了本不存在的失败。讨论模式早在 2026-07-17 就因同一原因改为 nil,其余三类被漏掉。
    ///
    /// 输入侧仍有独立护栏:`effectiveInputBudget` 用 `request.inputBudgetTokens` 封顶
    /// (用户可在「写作上下文预算」里配置),因此取消输出上限不会让输入无限膨胀。
    /// 已知边界:若用户把输入预算调到接近模型窗口上限,留给输出的空间会变小,模型可能
    /// 仍由 provider 侧自然截断——该情形沿用既有 `reachedOutputLimit` 提示,不在此层兜底。
    ///
    /// 不固定 temperature / topP：GPT-5 系列、Kimi 等只接受默认采样参数，固定值会被 400 拒绝。
    func modelParameters(for request: NovelRunRequest) -> NovelModelParameters {
        switch request.kind {
        case .quickStart:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        case .characterProposal:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        case .discussion:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        case .prose:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        case .polish:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        case .regenerate:
            NovelModelParameters(
                temperature: nil,
                topP: nil,
                maxOutputTokens: nil,
                reasoningLevel: .automatic
            )
        }
    }

    func modelMessages(plan: NovelInjectionPlan, userText: String) -> [NovelModelMessage] {
        var system = plan.prompt.systemText
        if !plan.contextText.isEmpty {
            system += "\n\n" + plan.contextText
        }
        return [
            NovelModelMessage(role: .system, content: system),
            NovelModelMessage(role: .user, content: userText)
        ]
    }

    func effectiveInputBudget(
        _ request: NovelRunRequest,
        model: NovelResolvedModel,
        parameters: NovelModelParameters
    ) throws -> Int {
        guard request.inputBudgetTokens > 0 else {
            throw NovelError.invalidInput("The generation input budget must be positive.")
        }
        guard let window = model.contextWindowTokens else {
            return request.inputBudgetTokens
        }
        // 用**预留值**反推输入预算,而不是 `parameters.maxOutputTokens`。
        // 2026-07-25 取消四类生成任务的硬上限时,该字段变为 nil,这里的留位随之
        // 归零——输入预算可以吃到「窗口 − 1024」,反过来挤掉输出空间。那是当时
        // 未察觉的连带损伤,此处补回:上限归上限(不发给模型),留位归留位(纯本地)。
        let output = request.kind.outputReservationTokens
        let available = max(0, window - output - 1_024)
        guard available > 0 else {
            throw NovelError.injectionBudgetExceeded(
                required: 1,
                limit: available,
                items: [NovelInjectionBudgetItem(
                    label: "Minimum input context",
                    estimatedTokens: 1
                )]
            )
        }
        return min(request.inputBudgetTokens, available)
    }

    func failure(from error: Error, fallbackCode: String) -> NovelFailure {
        if let failure = error as? NovelModelFailure {
            return NovelFailure(
                code: failure.code,
                message: failure.message,
                isRetryable: failure.isRetryable
            )
        }
        return NovelFailure(
            code: fallbackCode,
            message: error.localizedDescription,
            isRetryable: true
        )
    }

    func yieldReplayTerminal(
        _ run: NovelActiveRunRecord,
        document: NovelProjectDocumentV1,
        to continuation: AsyncStream<NovelRunEvent>.Continuation
    ) {
        let message = document.sessions
            .first(where: { $0.id == run.sessionID })?
            .messages
            .first(where: { $0.id == run.messageID })
        let snapshot = message.map {
            NovelSessionMessageSnapshot(
                projectID: document.project.id,
                branchID: run.branchID,
                message: $0
            )
        }
        switch run.status {
        case .running:
            break
        case .completed:
            if let snapshot { continuation.yield(.completed(snapshot)) }
        case .interrupted:
            continuation.yield(.interrupted(snapshot))
        case .failed:
            continuation.yield(.failed(run.terminalFailure ?? NovelFailure(
                code: "generation_failed",
                message: "Novel generation failed.",
                isRetryable: true
            )))
        }
    }
}
