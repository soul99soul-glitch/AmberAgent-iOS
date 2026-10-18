import Foundation
import Observation
@preconcurrency import Shared

@MainActor
private final class IOSCouncilStreamTail {
    var body = ""
}

enum IOSCouncilRoomRunnerError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyObjective
    case emptyOutput(String)
    case generationFailed(String)
    case timedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "当前服务商缺少 API Key。"
        case .emptyObjective: "议题为空。"
        case .emptyOutput(let stage): "\(stage)没有返回内容。"
        case .generationFailed(let message): "模型生成失败：\(message)"
        case .timedOut(let speaker): "\(speaker) 连续无输出，已超时。"
        case .cancelled: "模型议会已取消。"
        }
    }
}

private final class IOSCouncilStreamHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var lastOutputNanoseconds = DispatchTime.now().uptimeNanoseconds

    func recordOutput() {
        lock.lock()
        lastOutputNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func hasBeenSilent(for timeoutNanoseconds: UInt64) -> Bool {
        lock.lock()
        let lastOutputNanoseconds = self.lastOutputNanoseconds
        lock.unlock()
        return DispatchTime.now().uptimeNanoseconds &- lastOutputNanoseconds >= timeoutNanoseconds
    }
}

private struct IOSCouncilModelRoute {
    let providerSetting: ProviderSetting
    let model: Model

    var descriptor: IOSCouncilModelRouteDescriptor {
        IOSCouncilModelRouteDescriptor(
            providerId: providerSetting.id.description(),
            modelId: model.modelId
        )
    }
}

@MainActor
final class IOSCouncilRoomRunner {
    private let streamer: any IOSCouncilTextStreaming
    private let researcher: any IOSCouncilResearching
    private let taskStore: IOSAdvancedTaskStore
    private let permissionStore: IOSPermissionStore?
    private let timeoutUnitNanoseconds: UInt64
    private var runGeneration: UInt64 = 0
    private var activeRunGeneration: UInt64?
    private var activeTaskId: String?

    init(
        streamer: any IOSCouncilTextStreaming = IOSCouncilTextStreamer(),
        researcher: any IOSCouncilResearching = IOSCouncilSearchResearcher(),
        taskStore: IOSAdvancedTaskStore = .shared,
        permissionStore: IOSPermissionStore? = nil,
        timeoutUnitNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.streamer = streamer
        self.researcher = researcher
        self.taskStore = taskStore
        self.permissionStore = permissionStore
        self.timeoutUnitNanoseconds = timeoutUnitNanoseconds
    }

    func cancel() {
        runGeneration &+= 1
        activeRunGeneration = nil
        activeTaskId = nil
        streamer.cancel()
    }

    /// Reads the persisted status for the run currently shown by the room.
    /// The ViewModel still owns the lifecycle; this read only closes the narrow
    /// handoff window after `run()` has returned and before its caller releases
    /// the background lease.
    func taskStatus(taskId: String?) -> IOSAdvancedTaskStatus? {
        guard let taskId else { return nil }
        return taskStore.tasks.first(where: { $0.id == taskId })?.status
    }

    /// Returns the same durable record owned by this runner's injected store.
    /// Home and runtime projections must not reach around an injected runner to
    /// read the process-global store, or tests/custom owners can observe another task.
    func taskRecord(taskId: String?) -> IOSAdvancedTaskRecord? {
        guard let taskId else { return nil }
        return taskStore.tasks.first(where: { $0.id == taskId })
    }

    /// 由 ViewModel 在取消/系统执行权到期时写入任务终态；runner 本身仍只负责
    /// 取消 provider，避免把页面生命周期和 provider 流程混成第二套状态机。
    func markActiveTaskTerminal(
        taskId: String? = nil,
        status: IOSAdvancedTaskStatus,
        summary: String,
        retryable: Bool
    ) {
        guard let activeTaskId,
              (taskId == nil || taskId == activeTaskId) else { return }
        _ = taskStore.updateTask(
            id: activeTaskId,
            status: status,
            resultSummary: summary,
            error: "",
            retryable: retryable,
            cancelCapability: false,
            metadata: status == .interrupted
                ? ["interruption_reason": "background_execution_expired"]
                : nil
        )
    }

    func run(
        request: IOSCouncilRoomRunRequest,
        onEvent: @escaping @MainActor (IOSCouncilRoomEvent) -> Void = { _ in }
    ) async -> IOSCouncilRoomRunSummary {
        runGeneration &+= 1
        let currentRunGeneration = runGeneration
        if activeRunGeneration != nil {
            streamer.cancel()
        }
        activeRunGeneration = currentRunGeneration
        defer {
            if activeRunGeneration == currentRunGeneration {
                activeRunGeneration = nil
                activeTaskId = nil
            }
        }
        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = request.settings.normalized(currentModelId: request.currentModelId)
        let limits = settings.limits.normalized()
        let availableRoutes = modelRoutes(for: request)
        func resolveRoute(providerId: String?, modelId: String) -> IOSCouncilModelRoute {
            resolvedRoute(
                providerId: providerId,
                modelId: modelId,
                request: request,
                routes: availableRoutes
            )
        }
        let task: IOSAdvancedTaskRecord
        if let continuation = request.continuation,
           let existing = taskStore.tasks.first(where: { $0.id == continuation.taskId }) {
            task = taskStore.updateTask(
                id: existing.id,
                status: .running,
                resultSummary: "",
                error: "",
                retryable: false,
                cancelCapability: true,
                metadata: [
                    "continuation_round": String(continuation.nextRound),
                    "continuation_base_completed": "true"
                ]
            ) ?? existing
        } else {
            let continuation = request.continuation
            let metadata = continuation.map {
                [
                    "room_mode": request.mode.rawValue,
                    "host_model": settings.host.modelId,
                    "research_consent": request.researchConsent.rawValue,
                    "continuation_round": String($0.nextRound),
                    "continuation_base_completed": "true"
                ]
            } ?? [
                "room_mode": request.mode.rawValue,
                "host_model": settings.host.modelId,
                "research_consent": request.researchConsent.rawValue
            ]
            task = taskStore.startTask(
                id: request.taskId ?? continuation?.taskId,
                kind: .modelCouncil,
                title: "\(request.mode.title) · \((continuation?.originalObjective ?? objective).prefix(34))",
                objective: continuation?.originalObjective ?? objective,
                toolScope: continuation == nil && request.researchConsent == .allowed
                    ? ["search_web", "scrape_web"]
                    : [],
                budgetSummary: "mode \(request.mode.rawValue) · max seats \(limits.maxSeats) · rounds \(limits.defaultRounds) · budget \(limits.outputBudgetCharacters) chars",
                sourceToolName: "council_room",
                metadata: metadata
            )
        }
        activeTaskId = task.id
        onEvent(.taskStarted(task.id))

        guard !objective.isEmpty else {
            let message = IOSCouncilRoomRunnerError.emptyObjective.localizedDescription
            _ = taskStore.updateTask(
                id: task.id,
                status: .failed,
                resultSummary: message,
                error: message,
                retryable: true,
                cancelCapability: false
            )
            return IOSCouncilRoomRunSummary(
                taskId: task.id,
                status: .failed,
                finalTopic: "",
                finalAnswer: "",
                failureReason: message,
                seatNames: [],
                failedSeats: [],
                transcript: ""
            )
        }

        let currentRoute = resolveRoute(
            providerId: request.providerSetting.id.description(),
            modelId: request.currentModelId
        )
        if let issue = ChatProviderConfiguration.issue(
            for: currentRoute.model,
            provider: currentRoute.providerSetting
        ) {
            let message = issue.message
            onEvent(.append(systemMessage(body: message, subtitle: "配置阻塞", status: .failed)))
            _ = taskStore.updateTask(
                id: task.id,
                status: .failed,
                resultSummary: message,
                error: message,
                retryable: true,
                cancelCapability: false
            )
            return IOSCouncilRoomRunSummary(
                taskId: task.id,
                status: .failed,
                finalTopic: "",
                finalAnswer: "",
                failureReason: message,
                seatNames: [],
                failedSeats: [],
                transcript: message
            )
        }

        recordResearchConsent(request.researchConsent, objective: objective, runId: task.id)

        let continuedHost = request.continuation?.speakers.first(where: \.isHost)
        let hostRoute = resolveRoute(
            providerId: continuedHost?.providerId,
            modelId: continuedHost?.modelId ?? settings.host.modelId
        )
        let host = continuedHost.map { speaker in
            IOSCouncilRoomSpeaker(
                id: speaker.id,
                name: speaker.name,
                rolePrompt: speaker.rolePrompt,
                modelId: hostRoute.model.modelId,
                providerId: hostRoute.providerSetting.id.description(),
                reasoning: speaker.reasoning,
                prompt: speaker.prompt,
                isHost: true
            )
        } ?? IOSCouncilRoomSpeaker(
            id: "host",
            name: "主持人",
            rolePrompt: settings.host.prompt,
            modelId: hostRoute.model.modelId,
            providerId: hostRoute.providerSetting.id.description(),
            reasoning: settings.host.reasoning,
            prompt: settings.host.prompt,
            isHost: true
        )
        // 静态默认席位仅作为「主持人动态规划失败」时的兜底。
        var activeSeats = if let continuation = request.continuation {
            continuation.speakers.filter { !$0.isHost }.map { seat in
                let route = resolveRoute(providerId: seat.providerId, modelId: seat.modelId)
                return IOSCouncilRoomSpeaker(
                    id: seat.id,
                    name: seat.name,
                    rolePrompt: seat.rolePrompt,
                    modelId: route.model.modelId,
                    providerId: route.providerSetting.id.description(),
                    reasoning: seat.reasoning,
                    prompt: seat.prompt,
                    isHost: false
                )
            }
        } else {
            settings.defaultSeats(currentModelId: request.currentModelId).map { seat in
                let route = resolveRoute(providerId: nil, modelId: seat.modelId)
                return IOSCouncilRoomSpeaker(
                    id: seat.id,
                    name: seat.name,
                    rolePrompt: seat.rolePrompt,
                    modelId: route.model.modelId,
                    providerId: route.providerSetting.id.description(),
                    reasoning: seat.reasoning,
                    prompt: seat.prompt,
                    isHost: false
                )
            }
        }
        // 兜底注入内置默认席位,只在以下两种情况:动态生成开(这只是占位,稍后会被主持人
        // 动态规划替换);或用户一个席位都没配(否则会变成只有主持人的空议会)。动态关 + 用户
        // 已添加 ≥1 个席位时,尊重用户配置,不再塞入无关的默认人设(honor「只用已添加的席位」)。
        if activeSeats.count < 2,
           request.continuation == nil,
           request.dynamicSeatGeneration || activeSeats.isEmpty {
            activeSeats = Array(IOSCouncilRoomSettings.defaults(currentModelId: request.currentModelId)
                .defaultSeats(currentModelId: request.currentModelId)
                .prefix(limits.maxSeats)
                .map {
                    let route = resolveRoute(providerId: nil, modelId: $0.modelId)
                    return IOSCouncilRoomSpeaker(
                        id: $0.id,
                        name: $0.name,
                        rolePrompt: $0.rolePrompt,
                        modelId: route.model.modelId,
                        providerId: route.providerSetting.id.description(),
                        reasoning: $0.reasoning,
                        prompt: $0.prompt,
                        isHost: false
                    )
                })
        }

        var transcript = request.continuation?.priorTranscript.trimmedNilIfBlank.map { [$0] } ?? []
        var failedSeatIds = Set<String>()
        onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
        if request.continuation == nil {
            onEvent(.state("主持调研中"))
            onEvent(.append(dividerMessage("主持调研")))
        } else {
            onEvent(.state("追问讨论中"))
        }

        let research: IOSCouncilResearchBundle
        if request.continuation != nil {
            research = IOSCouncilResearchBundle(searches: [], scrapedPages: [], failures: [])
        } else if request.researchConsent == .allowed {
            let researchQuery = request.researchObjective?.trimmedNilIfBlank ?? objective
            research = await researcher.research(
                objective: researchQuery,
                settings: request.searchSettings,
                maxSearches: 4,
                maxScrapes: 4
            )
        } else {
            research = IOSCouncilResearchBundle(
                searches: [],
                scrapedPages: [],
                failures: request.researchConsent == .denied ? ["用户选择本轮不联网调研。"] : ["搜索未启用。"]
            )
        }
        if request.continuation == nil {
            taskStore.appendLog(id: task.id, chunk: "research:\n\(research.summaryText)\n\n")
        } else {
            transcript.append("[你 · 追问] \(objective)")
            taskStore.appendLog(id: task.id, chunk: "[你 · 追问] \(objective)\n\n")
        }

        do {
            let finalTopic: String
            if let continuation = request.continuation {
                finalTopic = continuation.finalTopic.trimmedOr(continuation.originalObjective)
            } else {
                let topicMessageId = UUID()
                onEvent(.append(IOSCouncilRoomMessageEvent(
                    id: topicMessageId,
                    kind: .host,
                    speakerId: host.id,
                    author: host.name,
                    body: "调研和完善议题中...",
                    subtitle: "主持 · \(host.modelId)",
                    status: .speaking
                )))
                onEvent(.roster([host] + activeSeats, activeSpeakerId: host.id, failedSpeakerIds: failedSeatIds))
                let defaultSeatsForTopic = activeSeats
                let generatedTopic = try await streamWithTimeout(
                    runGeneration: currentRunGeneration,
                    seconds: limits.seatTimeoutSeconds,
                    timeoutLabel: "主持人议题整理"
                ) { recordOutput in
                    try await self.stream(
                        runGeneration: currentRunGeneration,
                        speaker: host,
                        systemPrompt: self.hostSystemPrompt(settings: settings),
                        userPrompt: self.finalTopicPrompt(
                            objective: objective,
                            research: research,
                            sourceMaterials: request.sourceMaterials,
                            limits: limits,
                            defaultSeats: defaultSeatsForTopic
                        ),
                        request: request,
                        onUpdate: { text, allowance in
                            if !text.isEmpty { recordOutput() }
                            onEvent(.updateMessage(
                                id: topicMessageId,
                                body: text.isEmpty ? "调研和完善议题中..." : text,
                                status: .speaking,
                                lagAllowance: allowance
                            ))
                        }
                    )
                }
                guard let generatedTopic = generatedTopic.trimmedNilIfBlank else {
                    onEvent(.updateMessage(
                        id: topicMessageId,
                        body: "主持人未返回议题。",
                        status: .failed,
                        lagAllowance: 1
                    ))
                    throw IOSCouncilRoomRunnerError.emptyOutput("最终议题")
                }
                try checkCancelled(runGeneration: currentRunGeneration)
                onEvent(.updateMessage(id: topicMessageId, body: generatedTopic, status: .completed, lagAllowance: 0))
                transcript.append("[\(host.name)] \(generatedTopic)")
                taskStore.appendLog(id: task.id, chunk: "[\(host.name)] \(generatedTopic)\n\n")
                finalTopic = generatedTopic
            }

            // 开关「动态席位生成」开 → 主持人按议题 + 调研单独输出一份严格 JSON 席位清单
            //（Android planned_seats 思路），贴合本议题;关 → 直接用用户已添加的席位,不自由发挥。
            if request.continuation != nil {
                onEvent(.append(dividerMessage("沿用本议会席位：\(activeSeats.map(\.name).joined(separator: "、"))")))
            } else if request.dynamicSeatGeneration {
                onEvent(.state("组建议员席位中"))
                // 组席调用失败（超时/抛错）时重试一次；调用成功但解析不出席位不重试，
                // 走下面的显式回退——避免把"调用挂了"和"模型没给 JSON"混为一谈。
                var seatPlanRawOrNil: String? = try? await streamWithTimeout(
                    runGeneration: currentRunGeneration,
                    seconds: limits.seatTimeoutSeconds,
                    timeoutLabel: "主持人组席"
                ) { recordOutput in
                    try await self.stream(
                        runGeneration: currentRunGeneration,
                        speaker: host,
                        systemPrompt: self.seatPlanSystemPrompt(),
                        userPrompt: self.seatPlanPrompt(
                            objective: objective,
                            finalTopic: finalTopic,
                            research: research,
                            limits: limits,
                            sourceMaterials: request.sourceMaterials
                        ),
                        request: request,
                        onUpdate: { text, _ in
                            if !text.isEmpty { recordOutput() }
                        }
                    )
                }
                if seatPlanRawOrNil == nil {
                    try checkCancelled(runGeneration: currentRunGeneration)
                    seatPlanRawOrNil = try? await streamWithTimeout(
                        runGeneration: currentRunGeneration,
                        seconds: limits.seatTimeoutSeconds,
                        timeoutLabel: "主持人组席重试"
                    ) { recordOutput in
                        try await self.stream(
                            runGeneration: currentRunGeneration,
                            speaker: host,
                            systemPrompt: self.seatPlanSystemPrompt(),
                            userPrompt: self.seatPlanPrompt(
                                objective: objective,
                                finalTopic: finalTopic,
                                research: research,
                                limits: limits,
                                sourceMaterials: request.sourceMaterials
                            ),
                            request: request,
                            onUpdate: { text, _ in
                                if !text.isEmpty { recordOutput() }
                            }
                        )
                    }
                }
                let seatPlanRaw = seatPlanRawOrNil ?? ""
                try checkCancelled(runGeneration: currentRunGeneration)
                let plannedSeats = Self.plannedSeatsFromJSON(
                    seatPlanRaw,
                    maxSeats: limits.maxSeats,
                    routes: Self.diverseSeatRoutes(
                        routes: availableRoutes.map(\.descriptor),
                        hostRoute: IOSCouncilModelRouteDescriptor(
                            providerId: host.providerId ?? request.providerSetting.id.description(),
                            modelId: host.modelId
                        )
                    )
                )
                let usedDynamicSeats = plannedSeats.count >= 2
                if usedDynamicSeats {
                    activeSeats = plannedSeats
                } else {
                    // 显式回退：动态组席没产出有效席位时，明说沿用了默认席位，而不是像
                    // 组席成功那样打印"已组建…工程、产品、风险"，让用户误以为动态生效。
                    onEvent(.append(dividerMessage(
                        "动态组席未返回有效席位，已沿用默认席位：\(activeSeats.map(\.name).joined(separator: "、"))"
                    )))
                    taskStore.appendLog(
                        id: task.id,
                        chunk: "dynamic seat plan fell back to defaults; raw=\(seatPlanRaw.prefix(200))\n\n"
                    )
                }
                let validation = try await validateDynamicSeatModels(
                    activeSeats,
                    hostRoute: IOSCouncilModelRouteDescriptor(
                        providerId: host.providerId ?? request.providerSetting.id.description(),
                        modelId: host.modelId
                    ),
                    request: request,
                    runGeneration: currentRunGeneration,
                    timeoutSeconds: min(15, limits.seatTimeoutSeconds)
                )
                activeSeats = validation.seats
                if !validation.failures.isEmpty {
                    let summary = validation.failures
                        .map { "\($0.modelId)：\($0.reason)" }
                        .joined(separator: "；")
                    onEvent(.append(dividerMessage("模型联通检查已替换不可用模型：\(validation.failures.map(\.modelId).joined(separator: "、"))")))
                    taskStore.appendLog(id: task.id, chunk: "dynamic model probe fallback: \(summary)\n\n")
                }
                if usedDynamicSeats {
                    onEvent(.append(dividerMessage("已组建 \(activeSeats.count) 位议员：\(activeSeats.map(\.name).joined(separator: "、"))")))
                }
            } else {
                onEvent(.append(dividerMessage("本轮议员（已添加席位）：\(activeSeats.map(\.name).joined(separator: "、"))")))
            }
            onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
            if request.continuation == nil {
                onEvent(.append(dividerMessage(request.mode == .debate ? "辩论开始" : "自由群聊开始")))
            }

            // 两种模式的新议会都使用默认轮数；追问只追加 continuation 指定的一轮。
            let finalRound = request.continuation?.nextRound ?? limits.defaultRounds
            let roundNumbers = request.continuation.map { [max(2, $0.nextRound)] }
                ?? Array(1...finalRound)
            for round in roundNumbers {
                try checkCancelled(runGeneration: currentRunGeneration)
                onEvent(.append(dividerMessage(Self.roundDividerTitle(round))))
                for seat in activeSeats where !failedSeatIds.contains(seat.id) {
                    try checkCancelled(runGeneration: currentRunGeneration)
                    onEvent(.state("\(seat.name) 发言中"))
                    onEvent(.roster([host] + activeSeats, activeSpeakerId: seat.id, failedSpeakerIds: failedSeatIds))
                    let messageId = UUID()
                    onEvent(.append(IOSCouncilRoomMessageEvent(
                        id: messageId,
                        kind: .seat,
                        speakerId: seat.id,
                        author: seat.name,
                        body: "思考中...",
                        subtitle: "\(seat.modelId) · \(seat.reasoning.title)",
                        status: .speaking
                    )))
                    let latestMessage = IOSCouncilStreamTail()
                    do {
                        let transcriptSnapshot = transcript
                        // 席位发言前可选联网查证：开关开 + 本轮允许联网(全局联网开) + 非追问
                        // 时，复用主持同一条调研链路为该席查一轮，把材料注入其发言 prompt。
                        // 该调用在 runner.run 内 → discussionTask 内 → 自动落在后台保活租约内。
                        let seatResearch: IOSCouncilResearchBundle
                        if request.seatWebSearch,
                           request.researchConsent == .allowed,
                           request.continuation == nil {
                            try checkCancelled(runGeneration: currentRunGeneration)
                            seatResearch = await researcher.research(
                                objective: "\(finalTopic)（\(seat.name)视角：\(seat.rolePrompt)）",
                                settings: request.searchSettings,
                                maxSearches: 2,
                                maxScrapes: 2
                            )
                        } else {
                            seatResearch = IOSCouncilResearchBundle(
                                searches: [], scrapedPages: [], failures: []
                            )
                        }
                        let output = try await streamWithTimeout(
                            runGeneration: currentRunGeneration,
                            seconds: limits.seatTimeoutSeconds,
                            timeoutLabel: seat.name
                        ) { recordOutput in
                            try await self.stream(
                                runGeneration: currentRunGeneration,
                                speaker: seat,
                                systemPrompt: self.seatSystemPrompt(seat: seat),
                                userPrompt: self.seatPrompt(
                                    objective: request.continuation?.originalObjective ?? objective,
                                    finalTopic: finalTopic,
                                    followUp: request.continuation == nil ? nil : objective,
                                    mode: request.mode,
                                    round: round,
                                    rounds: finalRound,
                                    transcript: transcriptSnapshot,
                                    budget: limits.outputBudgetCharacters,
                                    seatResearch: seatResearch
                                ),
                                request: request,
                                onUpdate: { text, allowance in
                                    if !text.isEmpty { recordOutput() }
                                    let shown = text.isEmpty
                                        ? "思考中..."
                                        : Self.sanitizeSeatOutput(text)
                                    // 判断是否更新 latestMessage.body 必须基于原始 text：占位符
                                    // "思考中..."(text 为空时)不算席位真实产出,否则失败兜底会把
                                    // 占位符当成已生成内容而漏掉"席位失败"提示。shown 仅负责显示。
                                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        latestMessage.body = shown
                                    }
                                    onEvent(.updateMessage(id: messageId, body: shown, status: .speaking, lagAllowance: allowance))
                                }
                            )
                        }
                        guard let output = Self.sanitizeSeatOutput(output).trimmedNilIfBlank else {
                            throw IOSCouncilRoomRunnerError.emptyOutput("\(seat.name)席位")
                        }
                        onEvent(.updateMessage(id: messageId, body: output, status: .completed, lagAllowance: 0))
                        transcript.append("[\(seat.name)] \(output)")
                        taskStore.appendLog(id: task.id, chunk: "[\(seat.name)] \(output)\n\n")
                    } catch {
                        if activeRunGeneration != currentRunGeneration
                            || error is CancellationError
                            || (error as? IOSCouncilRoomRunnerError) == .cancelled {
                            throw error
                        }
                        let reason = error.localizedDescription
                        failedSeatIds.insert(seat.id)
                        let failedBody = latestMessage.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "席位失败：\(reason)"
                            : latestMessage.body
                        onEvent(.updateMessage(id: messageId, body: failedBody, status: .failed, lagAllowance: 1))
                        onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
                        taskStore.appendLog(id: task.id, chunk: "[\(seat.name)] failed: \(reason)\n\n")
                    }
                }

                // 主持人轮末点评：非最后一轮时，主持人对本轮发言做点评
                // （指出矛盾 / 下轮重点），让下一轮有递进方向。
                if round < finalRound {
                    try checkCancelled(runGeneration: currentRunGeneration)
                    onEvent(.state("主持人轮末点评"))
                    onEvent(.append(dividerMessage("主持人轮末点评")))
                    let commentaryId = UUID()
                    onEvent(.append(IOSCouncilRoomMessageEvent(
                        id: commentaryId,
                        kind: .host,
                        speakerId: host.id,
                        author: host.name,
                        body: "点评中...",
                        subtitle: "第 \(round) 轮点评 · \(host.modelId)",
                        status: .speaking
                    )))
                    onEvent(.roster([host] + activeSeats, activeSpeakerId: host.id, failedSpeakerIds: failedSeatIds))
                    let latestCommentary = IOSCouncilStreamTail()
                    let roundTranscript = transcript.suffix(8).joined(separator: "\n\n")
                    do {
                        let commentary = try await streamWithTimeout(
                            runGeneration: currentRunGeneration,
                            seconds: limits.seatTimeoutSeconds,
                            timeoutLabel: "主持人点评"
                        ) { recordOutput in
                            try await self.stream(
                                runGeneration: currentRunGeneration,
                                speaker: host,
                                systemPrompt: self.hostSystemPrompt(settings: settings),
                                userPrompt: Self.roundEndCommentaryPrompt(
                                    objective: request.continuation?.originalObjective ?? objective,
                                    round: round,
                                    rounds: finalRound,
                                    roundTranscript: roundTranscript
                                ),
                                request: request,
                                onUpdate: { text, allowance in
                                    if !text.isEmpty { recordOutput() }
                                    let body = text.isEmpty ? "点评中..." : text
                                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        latestCommentary.body = text
                                    }
                                    onEvent(.updateMessage(id: commentaryId, body: body, status: .speaking, lagAllowance: allowance))
                                }
                            )
                        }
                        guard let commentary = commentary.trimmedNilIfBlank else {
                            throw IOSCouncilRoomRunnerError.emptyOutput("主持人点评")
                        }
                        onEvent(.updateMessage(id: commentaryId, body: commentary, status: .completed, lagAllowance: 0))
                        transcript.append("[\(host.name) · 第\(round)轮点评] \(commentary)")
                        taskStore.appendLog(id: task.id, chunk: "[\(host.name) · 第\(round)轮点评] \(commentary)\n\n")
                    } catch {
                        if activeRunGeneration != currentRunGeneration
                            || error is CancellationError
                            || (error as? IOSCouncilRoomRunnerError) == .cancelled {
                            throw error
                        }
                        let failedBody = latestCommentary.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "点评失败：\(error.localizedDescription)"
                            : latestCommentary.body
                        onEvent(.updateMessage(id: commentaryId, body: failedBody, status: .failed, lagAllowance: 1))
                    }
                    onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
                }
                onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
                // 最后一轮不点评，直接进综合（阶段 6）。
            }

            try checkCancelled(runGeneration: currentRunGeneration)
            onEvent(.state("主持总结中"))
            onEvent(.append(dividerMessage(Self.hostSummaryDividerTitle)))
            let summaryId = UUID()
            onEvent(.append(IOSCouncilRoomMessageEvent(
                id: summaryId,
                kind: .host,
                speakerId: host.id,
                author: host.name,
                body: "总结中...",
                subtitle: "总结 · \(host.modelId)",
                status: .speaking
            )))
            onEvent(.roster([host] + activeSeats, activeSpeakerId: host.id, failedSpeakerIds: failedSeatIds))
            let transcriptForSynthesis = transcript
            let failedSeatsForSynthesis = activeSeats
                .filter { failedSeatIds.contains($0.id) }
                .map(\.name)
            let summary = try await streamWithTimeout(
                runGeneration: currentRunGeneration,
                seconds: limits.seatTimeoutSeconds,
                timeoutLabel: "主持人最终综合"
            ) { recordOutput in
                try await self.stream(
                    runGeneration: currentRunGeneration,
                    speaker: host,
                    systemPrompt: self.hostSystemPrompt(settings: settings),
                    userPrompt: self.synthesisPrompt(
                        objective: request.continuation?.originalObjective ?? objective,
                        finalTopic: finalTopic,
                        followUp: request.continuation == nil ? nil : objective,
                        transcript: transcriptForSynthesis,
                        failedSeats: failedSeatsForSynthesis
                    ),
                    request: request,
                    onUpdate: { text, allowance in
                        if !text.isEmpty { recordOutput() }
                        onEvent(.updateMessage(id: summaryId, body: text.isEmpty ? "总结中..." : text, status: .speaking, lagAllowance: allowance))
                    }
                )
            }
            guard let summary = summary.trimmedNilIfBlank else {
                onEvent(.updateMessage(
                    id: summaryId,
                    body: "主持人未返回总结。",
                    status: .failed,
                    lagAllowance: 1
                ))
                throw IOSCouncilRoomRunnerError.emptyOutput("最终综合")
            }
            onEvent(.updateMessage(id: summaryId, body: summary, status: .completed, lagAllowance: 0))
            transcript.append("[\(host.name)] \(summary)")
            taskStore.appendLog(id: task.id, chunk: "[\(host.name)] \(summary)\n\n")
            onEvent(.roster([host] + activeSeats, activeSpeakerId: nil, failedSpeakerIds: failedSeatIds))
            onEvent(.state("就绪"))

            let finalTranscript = clippedTranscript(transcript, budget: 24_000)
            let status: IOSAdvancedTaskStatus = .completed
            let failedNames = activeSeats.filter { failedSeatIds.contains($0.id) }.map(\.name)
            _ = taskStore.updateTask(
                id: task.id,
                status: status,
                resultSummary: failedNames.isEmpty ? "模型议会已完成讨论并生成结论。" : "模型议会已完成，失败席位：\(failedNames.joined(separator: ", "))。",
                logTail: finalTranscript,
                error: failedNames.isEmpty ? "" : "failed seats: \(failedNames.joined(separator: ", "))",
                retryable: !failedNames.isEmpty,
                cancelCapability: false,
                metadata: [
                    "final_topic_digest": Self.digest(finalTopic),
                    "seat_names": activeSeats.map(\.name).joined(separator: ", ")
                ]
            )
            return IOSCouncilRoomRunSummary(
                taskId: task.id,
                status: status,
                finalTopic: finalTopic,
                finalAnswer: summary,
                failureReason: nil,
                seatNames: activeSeats.map(\.name),
                failedSeats: failedNames,
                transcript: finalTranscript
            )
        } catch {
            // System execution expiry is recorded by the owner before cancelling
            // the provider. Preserve that explicit interrupted terminal instead
            // of letting the generic cancellation catch overwrite it as cancelled.
            if let terminalRecord = taskStore.tasks.first(where: { $0.id == task.id }),
               terminalRecord.status == .interrupted || terminalRecord.status == .cancelled {
                return IOSCouncilRoomRunSummary(
                    taskId: task.id,
                    status: terminalRecord.status,
                    finalTopic: "",
                    finalAnswer: "",
                    failureReason: terminalRecord.resultSummary,
                    seatNames: activeSeats.map(\.name),
                    failedSeats: activeSeats.filter { failedSeatIds.contains($0.id) }.map(\.name),
                    transcript: clippedTranscript(transcript, budget: 24_000)
                )
            }
            let isCancel = activeRunGeneration != currentRunGeneration
                || error is CancellationError
                || (error as? IOSCouncilRoomRunnerError) == .cancelled
            let isTimeout: Bool
            if case .timedOut? = error as? IOSCouncilRoomRunnerError {
                isTimeout = true
            } else {
                isTimeout = false
            }
            let status: IOSAdvancedTaskStatus = isCancel ? .cancelled : (isTimeout ? .timedOut : .failed)
            let message = isCancel ? "模型议会已取消。" : error.localizedDescription
            let isFailedContinuation = request.continuation != nil
            onEvent(.state(isCancel ? "已取消" : (isTimeout ? "已超时" : "失败")))
            onEvent(.append(systemMessage(
                body: message,
                subtitle: isCancel ? "已取消" : (isTimeout ? "已超时" : "运行失败"),
                status: .failed
            )))
            _ = taskStore.updateTask(
                id: task.id,
                status: isFailedContinuation ? .completed : status,
                resultSummary: isFailedContinuation
                    ? "既有议会结论已保留，本轮追问未完成。"
                    : message,
                logTail: clippedTranscript(transcript, budget: 24_000),
                error: isFailedContinuation || isCancel ? "" : message,
                retryable: !isFailedContinuation,
                cancelCapability: false,
                metadata: request.continuation.map {
                    [
                        "continuation_round": String($0.nextRound),
                        "continuation_status": status.rawValue
                    ]
                }
            )
            return IOSCouncilRoomRunSummary(
                taskId: task.id,
                status: status,
                finalTopic: "",
                finalAnswer: "",
                failureReason: message,
                seatNames: activeSeats.map(\.name),
                failedSeats: activeSeats.filter { failedSeatIds.contains($0.id) }.map(\.name),
                transcript: clippedTranscript(transcript, budget: 24_000)
            )
        }
    }

    static func makeProviderSetting(baseUrl: String, apiKey: String) -> ProviderSetting {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "当前 OpenAI-compatible 配置",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: apiKey,
            baseUrl: baseUrl,
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    /// Council supports the same OpenAI/Claude provider objects used by Chat.
    /// Preserve the object, especially its stable id used by OAuth/Web credentials.
    static func resolveProviderSetting(selected: ProviderSetting?) -> ProviderSetting? {
        guard let selected else { return nil }
        guard selected is ProviderSetting.OpenAI || selected is ProviderSetting.Claude else { return nil }
        return selected
    }

    private func validateDynamicSeatModels(
        _ seats: [IOSCouncilRoomSpeaker],
        hostRoute: IOSCouncilModelRouteDescriptor,
        request: IOSCouncilRoomRunRequest,
        runGeneration: UInt64,
        timeoutSeconds: Int
    ) async throws -> (seats: [IOSCouncilRoomSpeaker], failures: [(modelId: String, reason: String)]) {
        var seenRoutes = Set<String>()
        let candidateRoutes = seats.compactMap { seat -> IOSCouncilModelRoute? in
            let route = resolvedRoute(providerId: seat.providerId, modelId: seat.modelId, request: request)
            let key = Self.routeKey(route.descriptor)
            guard key != Self.routeKey(hostRoute), seenRoutes.insert(key).inserted else { return nil }
            return route
        }
        var reachableRoutes = Set([Self.routeKey(hostRoute)])
        var failures: [(modelId: String, reason: String)] = []
        for route in candidateRoutes {
            try checkCancelled(runGeneration: runGeneration)
            if let issue = ChatProviderConfiguration.issue(for: route.model, provider: route.providerSetting) {
                failures.append((route.model.modelId, issue.message))
                continue
            }
            do {
                try await probeDynamicSeatModel(
                    route,
                    request: request,
                    runGeneration: runGeneration,
                    timeoutSeconds: timeoutSeconds
                )
                reachableRoutes.insert(Self.routeKey(route.descriptor))
            } catch {
                try checkCancelled(runGeneration: runGeneration)
                failures.append((route.model.modelId, error.localizedDescription))
            }
        }
        guard !failures.isEmpty else { return (seats, []) }

        let resolvedHostRoute = resolvedRoute(
            providerId: hostRoute.providerId,
            modelId: hostRoute.modelId,
            request: request
        )
        let reachableAlternatives = candidateRoutes.filter {
            reachableRoutes.contains(Self.routeKey($0.descriptor))
        }
        let fallbackRoutes = [resolvedHostRoute] + reachableAlternatives
        var fallbackIndex = 0
        let repairedSeats = seats.map { seat in
            let route = resolvedRoute(providerId: seat.providerId, modelId: seat.modelId, request: request)
            guard !reachableRoutes.contains(Self.routeKey(route.descriptor)) else { return seat }
            let fallbackRoute = fallbackRoutes[fallbackIndex % fallbackRoutes.count]
            fallbackIndex += 1
            return IOSCouncilRoomSpeaker(
                id: seat.id,
                name: seat.name,
                rolePrompt: seat.rolePrompt,
                modelId: fallbackRoute.model.modelId,
                providerId: fallbackRoute.providerSetting.id.description(),
                reasoning: seat.reasoning,
                prompt: seat.prompt,
                isHost: false
            )
        }
        return (repairedSeats, failures)
    }

    private func probeDynamicSeatModel(
        _ route: IOSCouncilModelRoute,
        request: IOSCouncilRoomRunRequest,
        runGeneration: UInt64,
        timeoutSeconds: Int
    ) async throws {
        let output = try await streamWithTimeout(
            runGeneration: runGeneration,
            seconds: timeoutSeconds,
            timeoutLabel: "\(route.model.modelId) 联通测试"
        ) { recordOutput in
            try await self.performDynamicSeatProbe(
                route,
                request: request,
                recordOutput: recordOutput
            )
        }
        guard output.trimmedNilIfBlank != nil else {
            throw IOSCouncilRoomRunnerError.emptyOutput("\(route.model.modelId) 联通测试")
        }
    }

    private func performDynamicSeatProbe(
        _ route: IOSCouncilModelRoute,
        request: IOSCouncilRoomRunRequest,
        recordOutput: @escaping @Sendable () -> Void
    ) async throws -> String {
        let matchingBaseParams = request.baseParams.flatMap { params in
            params.model.modelId == route.model.modelId
                && route.providerSetting.id.description() == request.providerSetting.id.description()
                ? params : nil
        }
        let params = TextGenerationParams(
            model: route.model,
            temperature: nil,
            topP: nil,
            maxTokens: KotlinInt(value: 16),
            tools: [],
            reasoningLevel: .off,
            customHeaders: matchingBaseParams?.customHeaders ?? route.model.customHeaders,
            customBody: matchingBaseParams?.customBody ?? route.model.customBodies
        )
        return try await streamer.streamText(
            providerSetting: route.providerSetting,
            messages: [UIMessage.companion.user(prompt: "只回复 OK")],
            params: params,
            onUpdate: { text, _ in
                if !text.isEmpty { recordOutput() }
            }
        )
    }

    private func stream(
        runGeneration: UInt64,
        speaker: IOSCouncilRoomSpeaker,
        systemPrompt: String,
        userPrompt: String,
        request: IOSCouncilRoomRunRequest,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        try checkCancelled(runGeneration: runGeneration)
        let route = resolvedRoute(
            providerId: speaker.providerId,
            modelId: speaker.modelId,
            request: request
        )
        let params = makeTextGenerationParams(
            route: route,
            reasoning: speaker.reasoning,
            outputBudgetCharacters: request.settings.limits.outputBudgetCharacters,
            request: request
        )
        let messages = [
            UIMessage.companion.system(prompt: systemPrompt),
            UIMessage.companion.user(prompt: userPrompt)
        ]
        let text = try await streamer.streamText(
            providerSetting: route.providerSetting,
            messages: messages,
            params: params,
            onUpdate: onUpdate
        )
        try checkCancelled(runGeneration: runGeneration)
        return text
    }

    private func streamWithTimeout(
        runGeneration: UInt64,
        seconds: Int,
        timeoutLabel: String,
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> String
    ) async throws -> String {
        let timeoutNanoseconds = UInt64(max(1, seconds)) * timeoutUnitNanoseconds
        let pollIntervalNanoseconds = max(1, min(timeoutNanoseconds / 4, 250_000_000))
        let heartbeat = IOSCouncilStreamHeartbeat()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await operation {
                    heartbeat.recordOutput()
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                    if heartbeat.hasBeenSilent(for: timeoutNanoseconds) {
                        throw IOSCouncilRoomRunnerError.timedOut(timeoutLabel)
                    }
                }
            }
            do {
                guard let result = try await group.next() else {
                    throw IOSCouncilRoomRunnerError.timedOut(timeoutLabel)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if activeRunGeneration == runGeneration {
                    streamer.cancel()
                }
                throw error
            }
        }
    }

    private func makeTextGenerationParams(
        route: IOSCouncilModelRoute,
        reasoning: IOSCouncilReasoningPreset,
        outputBudgetCharacters: Int,
        request: IOSCouncilRoomRunRequest
    ) -> TextGenerationParams {
        let model = route.model
        let abilities = route.model.abilities
        let matchingBaseParams = request.baseParams.flatMap { params in
            params.model.modelId == model.modelId
                && route.providerSetting.id.description() == request.providerSetting.id.description()
                ? params : nil
        }
        let maxTokens = Int32(min(max(outputBudgetCharacters / 4, 512), 8_192))
        return TextGenerationParams(
            model: model,
            // 不固定温度：GPT-5 系列、Kimi 等只接受默认温度，固定值会被 400 拒绝。
            temperature: nil,
            topP: matchingBaseParams?.topP,
            maxTokens: KotlinInt(value: maxTokens),
            tools: [],
            reasoningLevel: abilities.contains(.reasoning) ? reasoning.reasoningLevel : .off,
            customHeaders: matchingBaseParams?.customHeaders ?? model.customHeaders,
            customBody: matchingBaseParams?.customBody ?? model.customBodies
        )
    }

    private func modelRoutes(for request: IOSCouncilRoomRunRequest) -> [IOSCouncilModelRoute] {
        var providers = request.providerSettings
        let currentProviderId = request.providerSetting.id.description()
        if !providers.contains(where: { $0.id.description() == currentProviderId }) {
            providers.insert(request.providerSetting, at: 0)
        }
        if providers.isEmpty {
            providers = [request.providerSetting]
        }

        var routes: [IOSCouncilModelRoute] = []
        var seen = Set<String>()
        if let currentModel = request.currentModel,
           ChatProviderConfiguration.issue(for: currentModel, provider: request.providerSetting) == nil {
            let route = IOSCouncilModelRoute(providerSetting: request.providerSetting, model: currentModel)
            seen.insert(Self.routeKey(route.descriptor))
            routes.append(route)
        }
        for configured in ChatProviderConfiguration.configuredChatModels(in: providers) {
            for model in configured.models {
                guard let provider = ChatProviderConfiguration.provider(for: model, providers: providers),
                      provider.enabled,
                      ChatProviderConfiguration.issue(for: model, provider: provider) == nil else { continue }
                let route = IOSCouncilModelRoute(providerSetting: provider, model: model)
                guard seen.insert(Self.routeKey(route.descriptor)).inserted else { continue }
                routes.append(route)
            }
        }
        return routes
    }

    private func resolvedRoute(
        providerId: String?,
        modelId: String,
        request: IOSCouncilRoomRunRequest,
        routes providedRoutes: [IOSCouncilModelRoute]? = nil
    ) -> IOSCouncilModelRoute {
        let routes = providedRoutes ?? modelRoutes(for: request)
        let currentProviderId = request.providerSetting.id.description()
        let normalizedModelId = modelId.trimmedNilIfBlank ?? request.currentModelId

        if let providerId = providerId?.trimmedNilIfBlank {
            if let exact = routes.first(where: {
                $0.providerSetting.id.description() == providerId && $0.model.modelId == normalizedModelId
            }) {
                return exact
            }
        } else {
            if let currentProviderMatch = routes.first(where: {
                $0.providerSetting.id.description() == currentProviderId && $0.model.modelId == normalizedModelId
            }) {
                return currentProviderMatch
            }
            if let matchingModel = routes.first(where: { $0.model.modelId == normalizedModelId }) {
                return matchingModel
            }
        }

        if let currentRoute = routes.first(where: {
            $0.providerSetting.id.description() == currentProviderId
                && $0.model.modelId == request.currentModelId
        }) {
            return currentRoute
        }
        return IOSCouncilModelRoute(
            providerSetting: request.providerSetting,
            model: resolvedModel(modelId: request.currentModelId, request: request)
        )
    }

    static func routeKey(_ route: IOSCouncilModelRouteDescriptor) -> String {
        "\(route.providerId)\n\(route.modelId)"
    }

    private func resolvedModel(
        modelId: String,
        request: IOSCouncilRoomRunRequest
    ) -> Model {
        if let currentModel = request.currentModel,
           currentModel.modelId == modelId {
            return currentModel
        }
        if let configured = request.providerSetting.models.first(where: {
            $0.type == ModelType.chat && $0.modelId == modelId
        }) {
            return configured
        }
        let abilities = ModelRegistry.shared.MODEL_ABILITIES.getData(modelId: modelId) as? [ModelAbility] ?? []
        return Model(
            modelId: modelId,
            displayName: modelId,
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: abilities,
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
    }

    private func seatSystemPrompt(seat: IOSCouncilRoomSpeaker) -> String {
        """
        你是模型议会席位：\(seat.name)。
        你的职责：\(seat.rolePrompt)
        \(seat.prompt)

        在主持人组织下发言。不要自称主持人。输出要具体、短而有判断。

        重要：你没有联网或调用工具的能力，本轮也不会为你执行任何搜索。
        因此绝对不要输出 web_search、function call、tool use 之类的工具调用文本，
        不要写 "query … / num_results …" 这类搜索参数，也不要用代码围栏（如 ```html）
        去包裹任何"结构化"内容或搜索计划。请直接以自然语言给出你的判断与论据；
        若某点你不确定，用一句话说明不确定即可，不要假装去查。
        """
    }

    private func seatPrompt(
        objective: String,
        finalTopic: String,
        followUp: String?,
        mode: IOSCouncilRoomRunMode,
        round: Int,
        rounds: Int,
        transcript: [String],
        budget: Int,
        seatResearch: IOSCouncilResearchBundle = IOSCouncilResearchBundle(
            searches: [], scrapedPages: [], failures: []
        )
    ) -> String {
        let followUpSection = followUp.map {
            """

            用户本轮追问或补充：
            \($0)
            """
        } ?? ""
        // 席位发言前的联网查证材料（开关开启且本轮允许联网时由 runner 注入）；空则不渲染，
        // 保持与未启用时逐字一致的 prompt。标题用「本席联网查证」与主持的「联网调研要点」区分。
        let seatResearchSection = seatResearch.isEmpty
            ? ""
            : "\n\n本席联网查证要点（发言前为你查到的最新材料，可据此佐证，但勿照抄、勿编造其中没有的事实）：\n\(seatResearch.summaryText)"
        let instruction = followUp == nil
            ? "请从你的席位职责给出本轮发言。自由群聊要补充新角度；辩论模式要回应前文的核心判断、指出盲区或确认成立条件。"
            : "请从你的席位职责直接回应本轮追问，并结合已有讨论给出新增判断。自由群聊要补充新角度；辩论模式要回应前文的核心判断、指出盲区或确认成立条件。"
        return """
        原始议题：
        \(objective)

        主持人完善后的最终议题：
        \(finalTopic)
        \(followUpSection)\(seatResearchSection)

        模式：\(mode.title)
        轮次：\(round)/\(rounds)

        已有讨论：
        \(clippedTranscript(transcript, budget: max(2_000, budget / 2)))

        \(instruction)
        """
    }

    private func synthesisPrompt(
        objective: String,
        finalTopic: String,
        followUp: String?,
        transcript: [String],
        failedSeats: [String]
    ) -> String {
        let followUpSection = followUp.map {
            """

            用户本轮追问或补充：
            \($0)
            """
        } ?? ""
        let instruction = followUp == nil
            ? "请作为主持人给出结论：共识、分歧、风险、推荐决策和下一步。若有席位失败，明确说明结论的不确定性。"
            : "请作为主持人优先回答本轮追问，再给出更新后的共识、分歧、风险、推荐决策和下一步。若有席位失败，明确说明结论的不确定性。"
        return """
        原始议题：
        \(objective)

        最终议题：
        \(finalTopic)
        \(followUpSection)

        议会讨论：
        \(clippedTranscript(transcript, budget: 12_000))

        失败或缺席席位：
        \(failedSeats.isEmpty ? "无" : failedSeats.joined(separator: ", "))

        \(instruction)
        """
    }

    /// 主持人轮末点评 prompt：总结本轮发言，指出矛盾点和下一轮应聚焦的方向。
    static func roundEndCommentaryPrompt(
        objective: String,
        round: Int,
        rounds: Int,
        roundTranscript: String
    ) -> String {
        """
        原始议题：\(objective)

        当前轮次：第 \(round) 轮 / 共 \(rounds) 轮

        本轮发言：
        \(roundTranscript)

        请作为主持人点评本轮：1) 各席位观点的矛盾或共识；2) 下一轮应聚焦的核心问题或盲区。保持简短（150-250 字），不要重复各席位的原文。
        """
    }

    private func recordResearchConsent(_ consent: IOSCouncilResearchConsent, objective: String, runId: String) {
        guard consent == .allowed || consent == .denied else { return }
        let action: IOSToolApprovalAction = consent == .allowed ? .allowed : .denied
        let reason = consent == .allowed
            ? "Council Room research is enabled in the current settings."
            : "User denied Council Room host research for this run."
        for tool in ["search_web", "scrape_web"] {
            _ = permissionStore?.recordApproval(
                capabilityId: "ios.network.search_tools",
                toolName: tool,
                action: action,
                reason: reason,
                runId: runId,
                scopeDigest: "council_room",
                payloadDigest: Self.digest(objective)
            )
        }
    }

    private func checkCancelled(runGeneration: UInt64) throws {
        if activeRunGeneration != runGeneration || Task.isCancelled {
            if activeRunGeneration == runGeneration {
                streamer.cancel()
            }
            throw IOSCouncilRoomRunnerError.cancelled
        }
    }

    /// Divider titles the tool detail sheet splits its round tabs on.
    static let hostSummaryDividerTitle = "主持总结"

    static func roundDividerTitle(_ round: Int) -> String { "第 \(round) 轮" }

    static func isRoundDivider(_ body: String) -> Bool {
        body.hasPrefix("第 ") && body.hasSuffix(" 轮") && Int(body.dropFirst(2).dropLast(2)) != nil
    }

    private func dividerMessage(_ body: String) -> IOSCouncilRoomMessageEvent {
        IOSCouncilRoomMessageEvent(
            id: UUID(),
            kind: .divider,
            speakerId: nil,
            author: "议会",
            body: body,
            subtitle: nil,
            status: .completed
        )
    }

    private func systemMessage(body: String, subtitle: String, status: IOSCouncilRoomMessageStatus) -> IOSCouncilRoomMessageEvent {
        IOSCouncilRoomMessageEvent(
            id: UUID(),
            kind: .system,
            speakerId: nil,
            author: "议会",
            body: body,
            subtitle: subtitle,
            status: status
        )
    }

    private func clippedTranscript(_ transcript: [String], budget: Int) -> String {
        let text = transcript.joined(separator: "\n\n")
        guard text.count > budget else { return text }
        return String(text.suffix(budget))
    }

    static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension IOSCouncilRoomRunMode {
    var title: String {
        switch self {
        case .freeChat: "自由群聊"
        case .debate: "辩论"
        }
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
