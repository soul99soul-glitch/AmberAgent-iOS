import SwiftUI
import Observation
import PhotosUI
import SwiftStreamingMarkdown
import UIKit
import UniformTypeIdentifiers
@preconcurrency import Shared

@MainActor
@Observable
final class CouncilChatViewModel {
    enum DurableRunAwaitPoint {
        case start
        case configurationFailure
        case completion
    }

    /// Wraps the real durable call so ownership races can be paused in tests.
    typealias DurableRunAwaiter = @MainActor (
        DurableRunAwaitPoint, @MainActor () async -> Bool
    ) async -> Bool

    var inputText = ""
    var selectedMode: CouncilDiscussionMode = .freeChat
    var messages: [CouncilChatMessage] {
        didSet {
            guard messages.count != oldValue.count else { return }
            let nextDiscussionRound = Self.calculateDiscussionRound(in: messages)
            if discussionRound != nextDiscussionRound {
                discussionRound = nextDiscussionRound
            }
            let nextHasCouncilMessages = !messages.isEmpty
            if hasCouncilMessages != nextHasCouncilMessages {
                hasCouncilMessages = nextHasCouncilMessages
            }
        }
    }
    private(set) var discussionRound: Int
    private(set) var hasCouncilMessages: Bool
    var isRunning = false
    /// 流式拍恒为 1；终态排空拍随剩余积压连续衰减到 0（与 Chat/小说同源）。
    /// 视图在提交 `streamContentGrew(lagAllowance:)` 时携带，驱动据此收紧 τ_eff。
    var activeTailLagAllowance: CGFloat = 1
    var activeSheet: CouncilRuntimeSheet?
    var participants: [CouncilParticipant] = []
    var failedSpeakerIds: Set<String> = []
    var archiveErrorMessage: String?
    /// 只读重放:从「最近讨论」重开一场历史议会时为 true,隐藏输入条、不再归档/覆盖草稿。
    var isReplay = false

    /// Pending file/image materials for the next opening discussion (not follow-ups).
    var pendingFiles: [CouncilPendingFile] = []
    var pendingImages: [CouncilPendingImage] = []
    var attachmentErrorMessage: String?
    var isPreparingMaterials = false
    var materialsPreparationStatus = ""

    let roomSettingsStore: IOSCouncilRoomSettingsStore

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let sharedSettings: IOSSharedSettingsStore
    @ObservationIgnored private let providerRegistry: ProviderRegistryStore?
    @ObservationIgnored private let runner: IOSCouncilRoomRunner
    @ObservationIgnored private let transcriptDefaults: UserDefaults
    @ObservationIgnored private let archiveStore: CouncilRoomArchiveStore
    @ObservationIgnored private let visionRecognizer: CouncilVisionMaterialRecognizer
    @ObservationIgnored private var discussionTask: Task<Void, Never>?
    @ObservationIgnored private var materialsPreparationTask: Task<Void, Never>?
    /// Bumped on cancel / reset / openArchive so late file/vision completions cannot start a discussion.
    @ObservationIgnored private var materialsPrepGeneration: UInt64 = 0
    @ObservationIgnored private(set) var attachmentRoomGeneration: UInt64 = 0
    /// 后台期间等讨论跑完、跑完就还执行权的那个任务。
    @ObservationIgnored private var keepAliveReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var activeDiscussionID: UUID?
    @ObservationIgnored private var activeDurableRunID: String?
    @ObservationIgnored private let durableRunStore: IOSDurableRunStore?
    @ObservationIgnored private let durableRunAwaiter: DurableRunAwaiter
    private var currentObjective = ""
    private var currentFinalTopic = ""
    private var currentTaskId: String?
    @ObservationIgnored private var pendingObjective = ""
    @ObservationIgnored private var pendingSourceMaterials: String?
    @ObservationIgnored private var pendingResearchObjective: String?
    @ObservationIgnored private var lastRunObjective = ""
    @ObservationIgnored private var lastResearchAllowed = false
    /// 中段检查点节流:roster/append/消息完结等事件密集到达时,每个 300ms 窗口
    /// 最多触发一次离主线程写入,避免每条消息都触发 encode+write。终态检查点
    /// (结束/取消/切后台/恢复)不走节流,直接同步写以保证 load-after-save 顺序。
    @ObservationIgnored private var archiveThrottleTask: Task<Void, Never>?

    private var roomStateOverride: String?
    private var activeSpeakerId: String?
    private var invitedSpeakerIds: Set<String> = []

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore,
        providerRegistry: ProviderRegistryStore?,
        permissionStore: IOSPermissionStore,
        roomSettingsStore: IOSCouncilRoomSettingsStore = .shared,
        runner: IOSCouncilRoomRunner? = nil,
        transcriptDefaults: UserDefaults = .standard,
        archiveStore: CouncilRoomArchiveStore = .shared,
        visionRecognizer: CouncilVisionMaterialRecognizer = CouncilVisionMaterialRecognizer(),
        durableRunStore: IOSDurableRunStore? = nil,
        durableRunAwaiter: @escaping DurableRunAwaiter = { _, operation in await operation() }
    ) {
        let restoredRoom = CouncilTranscriptStore.load(defaults: transcriptDefaults)
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.providerRegistry = providerRegistry
        self.roomSettingsStore = roomSettingsStore
        self.runner = runner ?? IOSCouncilRoomRunner(permissionStore: permissionStore)
        self.transcriptDefaults = transcriptDefaults
        self.archiveStore = archiveStore
        self.visionRecognizer = visionRecognizer
        self.durableRunStore = durableRunStore
        self.durableRunAwaiter = durableRunAwaiter
        let initialMessages = restoredRoom?.messages.map { $0.restored() } ?? []
        self.messages = initialMessages
        self.discussionRound = Self.calculateDiscussionRound(in: initialMessages)
        self.hasCouncilMessages = !initialMessages.isEmpty
        if let restoredRoom {
            currentTaskId = restoredRoom.taskId.trimmedNilIfBlank
            currentObjective = restoredRoom.objective
            currentFinalTopic = restoredRoom.finalTopic ?? ""
            lastRunObjective = restoredRoom.objective
            selectedMode = CouncilDiscussionMode(rawValue: restoredRoom.modeRaw) ?? .freeChat
            participants = restoredRoom.participants.map { $0.restored() }
            failedSpeakerIds = Set(restoredRoom.failedSpeakerIds)
            invitedSpeakerIds = Set(participants.filter { !$0.isHost }.map(\.id))
            roomStateOverride = restoredRoom.statusRaw.trimmedNilIfBlank
        }
        if participants.isEmpty {
            refreshSettingsBackedParticipants()
        }
    }

    func persistTranscript() {
        // 重放历史议会时不要把只读快照写回单房间草稿,否则会覆盖实时房间的进度。
        guard !isReplay else { return }
        CouncilTranscriptStore.save(
            persistedRoom(taskId: currentTaskId ?? ""),
            defaults: transcriptDefaults
        )
    }

    func runtimeDidDisappear() {
        // 离开议会界面时做一次离主线程检查点,让「最近讨论」尽快看到当前进度;
        // 先取消节流任务,避免它在切走后再次触发写入。
        cancelScheduledArchive()
        archiveCurrentRoom(deferred: true)
    }

    func runtimeWillEnterBackground() {
        persistTranscript()
        // 落盘是终止路径:取消节流任务并同步落盘,同步写会使在途延迟写失效。
        // 但讨论本身不再终止——下面拿后台执行权让它自己跑完。
        cancelScheduledArchive()
        archiveCurrentRoom()
        beginBackgroundKeepAliveIfRunning()
    }

    /// 讨论还在跑就拿后台执行权，跑完自动还回去。
    /// 议会没有「后台重跑」那一路，执行权被系统收走时取消当前 owner 并保留可重试快照。
    /// 讨论还在跑、或还在解析材料，就拿后台执行权。
    private func beginBackgroundKeepAliveIfRunning() {
        if isPreparingMaterials {
            beginMaterialsKeepAlive()
        }
        guard let discussionID = activeDiscussionID else { return }
        beginBackgroundKeepAlive(for: discussionID)
    }

    private func keepAliveLeaseId(for discussionID: UUID) -> String {
        "council-\(discussionID.uuidString)"
    }

    private func beginBackgroundKeepAlive(for discussionID: UUID) {
        guard isRunning,
              activeDiscussionID == discussionID,
              let discussionTask else { return }
        let leaseId = keepAliveLeaseId(for: discussionID)
        keepAliveReleaseTask?.cancel()
        BackgroundGenerationKeepAlive.shared.begin(
            leaseId,
            title: IOSAppLocalization.string(
                "Amber 议会讨论中",
                defaultValue: "Amber 议会讨论中"
            ),
            subtitle: currentObjective.isEmpty
                ? IOSAppLocalization.string("模型议会", defaultValue: "模型议会")
                : currentObjective,
            onExpire: { [weak self] in
                self?.handleBackgroundKeepAliveExpiration(for: discussionID)
            },
            onSystemTaskExpiration: { [weak self] in
                self?.handleBackgroundKeepAliveExpiration(for: discussionID)
            }
        )
        keepAliveReleaseTask = Task { @MainActor [weak self] in
            await discussionTask.value
            // `Task<_, Never>.value` 不理会「等待方被取消」，所以上一轮遗留的
            // 这个任务照样会醒过来。醒来时租约可能已经属于新一轮讨论了——
            // 没这道 guard，旧任务会把新一轮的执行权还掉，新讨论在后台静默断流。
            guard !Task.isCancelled else { return }
            guard let self, self.activeDiscussionID == discussionID else { return }
            self.endBackgroundKeepAlive(for: discussionID)
        }
    }

    private func endBackgroundKeepAlive(for discussionID: UUID?) {
        guard let discussionID else { return }
        keepAliveReleaseTask?.cancel()
        keepAliveReleaseTask = nil
        BackgroundGenerationKeepAlive.shared.end(keepAliveLeaseId(for: discussionID))
    }

    private func updateBackgroundProgress(completed: Int64, subtitle: String? = nil) {
        guard let discussionID = activeDiscussionID else { return }
        BackgroundGenerationKeepAlive.shared.updateProgress(
            keepAliveLeaseId(for: discussionID),
            completed: completed,
            total: 4,
            subtitle: subtitle
        )
    }

    private func handleBackgroundKeepAliveExpiration(for discussionID: UUID) {
        guard activeDiscussionID == discussionID, isRunning else { return }
        // `run()` may already have returned and cleared its private activeTaskId
        // while this ViewModel is still between the summary and lease-release
        // statements. A terminal ledger means the generation won; only release
        // the stale lease and let the summary path finish.
        if runner.taskStatus(taskId: currentTaskId)?.isTerminal == true {
            endBackgroundKeepAlive(for: discussionID)
            return
        }
        stopAndCheckpointActiveDiscussion(
            taskStatus: .interrupted,
            terminalMessage: "后台执行已停止，可以重试。"
        )
    }

    var hasPendingMaterials: Bool {
        !pendingFiles.isEmpty || !pendingImages.isEmpty
    }

    /// Attachments only apply to a new opening discussion; follow-ups stay text-only.
    var canAttachMaterials: Bool {
        !isReplay && !isRunning && !isPreparingMaterials && !canContinueCurrentCouncil
    }

    var canSend: Bool {
        guard !isRunning, !isPreparingMaterials, currentConfigurationIssue == nil else { return false }
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if canContinueCurrentCouncil {
            return hasText
        }
        return hasText || hasPendingMaterials
    }

    /// Composer 旁展示；与 `canSend` 共用同一配置判定，避免灰掉发送却无说明。
    var configurationErrorMessage: String? {
        currentConfigurationIssue.map { issue in
            IOSAppLocalization.string(issue.message, defaultValue: issue.message)
        }
    }

    var composerPlaceholder: String {
        if canContinueCurrentCouncil {
            return IOSAppLocalization.string(
                "输入补充或追问，再讨论一轮",
                defaultValue: "输入补充或追问，再讨论一轮"
            )
        }
        if hasPendingMaterials {
            return IOSAppLocalization.string(
                "补充说明（可选），或直接发送从材料生成议题",
                defaultValue: "补充说明（可选），或直接发送从材料生成议题"
            )
        }
        return IOSAppLocalization.string(
            "输入议题开始，或上传文件/图片",
            defaultValue: "输入议题开始，或上传文件/图片"
        )
    }

    var currentModelId: String {
        let trimmed = sharedSettings.resolveCurrentModelId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-4o" : trimmed
    }

    var hostDisplayName: String {
        participants.first(where: \.isHost)?.displayNameForDisplay ?? Self.hostName(for: currentModelId)
    }

    /// 当前若处于只读重放,返回被重放那场的 taskId(供历史列表高亮),否则 nil。
    var activeReplayTaskId: String? {
        isReplay ? currentTaskId : nil
    }

    /// 首页只读投影当前房间；历史归档不参与，避免点“继续”后落到另一场议会。
    var homeResumeContext: CouncilHomeResumeContext? {
        guard !isReplay,
              let currentTaskId,
              // 首页 body 读取：只判存在，不读盘解码整份存档（首页在聊天页下方仍随数据重算）。
              archiveStore.exists(taskId: currentTaskId),
              let task = runner.taskRecord(taskId: currentTaskId) else {
            return nil
        }

        let effectiveStatus: IOSAdvancedTaskStatus
        if task.status == .completed,
           let rawStatus = task.metadata["continuation_status"],
           let continuationStatus = IOSAdvancedTaskStatus(rawValue: rawStatus) {
            switch continuationStatus {
            case .failed, .cancelled, .timedOut, .interrupted:
                effectiveStatus = continuationStatus
            case .queued, .running, .approvalRequired, .completed:
                effectiveStatus = task.status
            }
        } else {
            effectiveStatus = task.status
        }
        let canContinue = canContinueCurrentCouncil
        switch effectiveStatus {
        case .queued, .running, .approvalRequired:
            break
        case .failed, .cancelled, .timedOut, .interrupted:
            guard canContinue else { return nil }
        case .completed:
            return nil
        }

        return CouncilHomeResumeContext(
            id: task.id,
            title: currentObjective.trimmedNilIfBlank ?? task.title,
            status: effectiveStatus,
            updatedAt: task.updatedAt,
            canContinue: canContinue
        )
    }

    func recoverInterruptedTasks(_ taskIds: [String]) {
        guard let currentTaskId, taskIds.contains(currentTaskId) else { return }
        // 恢复即终止路径:先取消节流任务,尾部再同步写一份「已中断」快照( bump 代数使
        // 任何在途延迟写失效),保证 load 之后看到的是恢复后的最新事实。
        cancelScheduledArchive()
        if let room = archiveStore.load(taskId: currentTaskId) {
            currentObjective = room.objective
            currentFinalTopic = room.finalTopic ?? ""
            lastRunObjective = room.objective
            selectedMode = CouncilDiscussionMode(rawValue: room.modeRaw) ?? selectedMode
            participants = room.participants.map { $0.restored() }
            failedSpeakerIds = Set(room.failedSpeakerIds)
            messages = room.messages.map { $0.restored() }
        }
        if currentFinalTopic.trimmedNilIfBlank == nil {
            currentFinalTopic = currentObjective
        }
        finishStreamingMessages(as: .failed)
        isRunning = false
        activeSpeakerId = nil
        invitedSpeakerIds.removeAll()
        roomStateOverride = IOSAdvancedTaskStatus.interrupted.title
        appendMessage(
            kind: .system,
            author: "议会",
            body: "上次讨论已中断，可以继续补充或重新发起。",
            systemImage: "pause.circle",
            tint: AmberTheme.accentRed,
            subtitle: IOSAdvancedTaskStatus.interrupted.title,
            status: .failed
        )
        persistTranscript()
        archiveCurrentRoom()
    }

    func reconcileDurableRuns() async {
        guard let durableRunStore,
              let runs = try? await durableRunStore.recoverableRuns(
            descriptorIds: [IOSDurableRunStore.Descriptor.council]
        ) else { return }
        for run in runs where run.runId != activeDurableRunID {
            guard let ref = run.inputSnapshotRef, ref.hasPrefix("council:") else { continue }
            let taskId = String(ref.dropFirst("council:".count))
            let record = runner.taskRecord(taskId: taskId)
            let status: AgentRunStatus
            if record?.metadata["continuation_status"] == "interrupted" ||
                record?.metadata["interruption_reason"] == "process_terminated" {
                status = .interrupted
            } else {
                status = Self.durableStatus(for: record?.status ?? .interrupted)
            }
            _ = try? await durableRunStore.transitionFromAnyActive(
                runId: run.runId,
                to: status,
                detail: record?.compactSummary ?? "process_restarted"
            )
        }
    }

    /// 当前讨论轮次：只数真正的「第 N 轮」轮次分隔，不把开场 / 主持调研 / 席位组建 /
    /// 轮末点评 / 主持总结等阶段胶囊也算进轮次（否则开场阶段就会误显示「第 6 轮」）。
    private static func calculateDiscussionRound(in messages: [CouncilChatMessage]) -> Int {
        let roundMarkers = messages.filter {
            $0.kind == .divider
                && $0.body.range(of: #"^第\s*\d+\s*轮$"#, options: .regularExpression) != nil
        }
        return max(1, roundMarkers.count)
    }

    var availableModelIds: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for model in sharedSettings.resolveCurrentProviderSetting()?.models ?? []
            where model.type == ModelType.chat {
            let modelId = model.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty, seen.insert(modelId).inserted else { continue }
            ids.append(modelId)
        }
        let current = currentModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, seen.insert(current).inserted {
            ids.insert(current, at: 0)
        }
        return ids
    }

    func state(for participant: CouncilParticipant) -> CouncilParticipantState {
        if failedSpeakerIds.contains(participant.id) {
            return .failed
        }
        if activeSpeakerId == participant.id {
            return .speaking
        }
        if invitedSpeakerIds.contains(participant.id) {
            return .invited
        }
        return .idle
    }

    func addPendingImage(dataUrl: String, previewData: Data, displayName: String = "图片") {
        guard canAttachMaterials else {
            attachmentErrorMessage = "当前只能在新议题里附加材料；追问请用文字补充。"
            return
        }
        guard pendingImages.count < CouncilMaterialLimits.maxImages else {
            attachmentErrorMessage = "一次最多附加 \(CouncilMaterialLimits.maxImages) 张图片"
            return
        }
        pendingImages.append(
            CouncilPendingImage(dataUrl: dataUrl, previewData: previewData, displayName: displayName)
        )
        attachmentErrorMessage = nil
    }

    func removePendingImage(_ id: CouncilPendingImage.ID) {
        pendingImages.removeAll { $0.id == id }
    }

    func removePendingFile(_ id: CouncilPendingFile.ID) {
        pendingFiles.removeAll { $0.id == id }
    }

    func clearPendingMaterials() {
        pendingFiles.removeAll()
        pendingImages.removeAll()
    }

    /// Cancel in-flight file parse / vision prep and drop late completions via generation bump.
    func cancelMaterialsPreparation(showCancelledMessage: Bool = true) {
        invalidateMaterialsPreparation(showCancelledMessage: showCancelledMessage)
    }

    func attachPickedFile(url: URL) {
        guard canAttachMaterials else {
            attachmentErrorMessage = IOSAppLocalization.string(
                "当前只能在新议题里附加材料；追问请用文字补充。",
                defaultValue: "当前只能在新议题里附加材料；追问请用文字补充。"
            )
            return
        }
        guard pendingFiles.count < CouncilMaterialLimits.maxFiles else {
            attachmentErrorMessage = IOSAppLocalization.formatted(
                "一次最多附加 %lld 个文件",
                defaultValue: "一次最多附加 %lld 个文件",
                arguments: [Int64(CouncilMaterialLimits.maxFiles)]
            )
            return
        }
        let generation = beginMaterialsPreparation(status: IOSAppLocalization.string(
            "正在解析文件…",
            defaultValue: "正在解析文件…"
        ))
        materialsPreparationTask = Task { [weak self] in
            let outcome = await CouncilFileMaterialLoader.load(url: url)
            await MainActor.run {
                guard let self else { return }
                guard self.finishMaterialsPreparation(ifGeneration: generation) else { return }
                switch outcome {
                case .success(let file):
                    // Re-check caps after async gap (another file may have landed).
                    if self.pendingFiles.count >= CouncilMaterialLimits.maxFiles {
                        self.attachmentErrorMessage = IOSAppLocalization.formatted(
                            "一次最多附加 %lld 个文件",
                            defaultValue: "一次最多附加 %lld 个文件",
                            arguments: [Int64(CouncilMaterialLimits.maxFiles)]
                        )
                        return
                    }
                    self.pendingFiles.append(file)
                    self.attachmentErrorMessage = nil
                case .failure(let message):
                    self.attachmentErrorMessage = message
                }
            }
        }
    }

    func send() {
        guard canSend, !isRunning, !isPreparingMaterials, !isReplay, activeDiscussionID == nil else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuation = makeContinuationContext()
        if continuation != nil {
            // Follow-ups are text-only.
            clearPendingMaterials()
            pendingObjective = text
            pendingSourceMaterials = nil
            pendingResearchObjective = nil
            startPendingDiscussion(researchAllowed: sharedSettings.snapshot.enableWebSearch)
            return
        }

        if !hasPendingMaterials {
            pendingObjective = text
            pendingSourceMaterials = nil
            pendingResearchObjective = nil
            startPendingDiscussion(researchAllowed: sharedSettings.snapshot.enableWebSearch)
            return
        }

        // Opening discussion with materials: parse images first, then start.
        let files = pendingFiles
        let images = pendingImages
        let generation = beginMaterialsPreparation(
            status: IOSAppLocalization.string(
                images.isEmpty ? "正在整理材料…" : "正在识别图片…",
                defaultValue: images.isEmpty ? "正在整理材料…" : "正在识别图片…"
            )
        )
        materialsPreparationTask = Task { [weak self] in
            guard let self else { return }
            let resolved: CouncilResolvedMaterials
            if images.isEmpty {
                resolved = CouncilResolvedMaterials(files: files, imageContexts: [])
            } else {
                let vision = await self.visionRecognizer.recognize(
                    images: images,
                    settings: self.sharedSettings.snapshot
                )
                if Task.isCancelled {
                    await MainActor.run {
                        _ = self.finishMaterialsPreparation(ifGeneration: generation)
                    }
                    return
                }
                switch vision {
                case .failure(let error):
                    await MainActor.run {
                        guard self.finishMaterialsPreparation(ifGeneration: generation) else { return }
                        self.attachmentErrorMessage = error.localizedDescription
                    }
                    return
                case .success(let contexts):
                    resolved = CouncilResolvedMaterials(files: files, imageContexts: contexts)
                }
            }
            if Task.isCancelled {
                await MainActor.run {
                    _ = self.finishMaterialsPreparation(ifGeneration: generation)
                }
                return
            }
            await MainActor.run {
                guard self.finishMaterialsPreparation(ifGeneration: generation) else { return }
                // Late completion after openArchive / reset / cancel must not start a run.
                guard !self.isReplay, !self.isRunning, self.activeDiscussionID == nil else { return }
                self.pendingObjective = CouncilMaterialsComposer.displayObjective(
                    userText: text,
                    hasMaterials: !resolved.isEmpty
                )
                let materialsBlock = resolved.promptBlock()
                self.pendingSourceMaterials = materialsBlock.isEmpty ? nil : materialsBlock
                self.pendingResearchObjective = CouncilMaterialsComposer.researchObjective(
                    userText: text,
                    materials: resolved
                )
                // Replace raw pending chips with a bubble summary; keep resolved for bubble body.
                self.clearPendingMaterials()
                self.startPendingDiscussion(
                    researchAllowed: self.sharedSettings.snapshot.enableWebSearch,
                    bubbleBody: CouncilMaterialsComposer.userBubbleBody(
                        userText: text,
                        materials: resolved
                    )
                )
            }
        }
    }

    func startPendingDiscussion(
        researchAllowed: Bool,
        bubbleBody: String? = nil
    ) {
        let text = pendingObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceMaterials = pendingSourceMaterials
        let researchObjective = pendingResearchObjective
        pendingObjective = ""
        pendingSourceMaterials = nil
        pendingResearchObjective = nil
        // Replay / archive views are read-only; never start a live run from late materials prep.
        guard !isReplay, !text.isEmpty, !isRunning, activeDiscussionID == nil else { return }
        let continuation = makeContinuationContext()
        if continuation == nil, currentTaskId != nil || !messages.isEmpty {
            resetRoom()
        }
        inputText = ""
        if continuation == nil {
            currentObjective = text
            lastRunObjective = text
            lastResearchAllowed = researchAllowed
        }
        roomStateOverride = nil
        failedSpeakerIds.removeAll()
        appendMessage(
            kind: .user,
            author: "你",
            body: bubbleBody ?? text,
            systemImage: "person.fill",
            tint: AmberTheme.accent,
            subtitle: continuation.map { "追问 · 第 \($0.nextRound) 轮" }
                ?? (sourceMaterials == nil ? nil : "含上传材料")
        )

        let discussionID = UUID()
        let taskId = continuation?.taskId ?? UUID().uuidString
        let durableRunId = "\(taskId):\(discussionID.uuidString)"
        activeDiscussionID = discussionID
        activeDurableRunID = durableRunId
        currentTaskId = taskId
        isRunning = true
        // 先保存用户已经提交的议题，再把 runner 交给异步任务；进程若在
        // `.taskStarted` 之前被终止，重载仍能看到这条输入。
        persistTranscript()
        archiveCurrentRoom()
        discussionTask = Task { [weak self] in
            await self?.runDiscussion(
                objective: text,
                researchAllowed: researchAllowed,
                discussionID: discussionID,
                taskId: taskId,
                durableRunId: durableRunId,
                continuation: continuation,
                sourceMaterials: continuation == nil ? sourceMaterials : nil,
                researchObjective: continuation == nil ? researchObjective : nil
            )
        }
        // 用户点击开始时就提交 continued processing；等 scenePhase 切到后台再提交已太晚。
        beginBackgroundKeepAlive(for: discussionID)
    }

    func cancelDiscussion() {
        // 用户主动停止也是终止路径:取消节流任务,尾部同步写会使在途延迟写失效。
        cancelScheduledArchive()
        runner.markActiveTaskTerminal(
            taskId: currentTaskId,
            status: .cancelled,
            summary: "本轮议会已停止。",
            retryable: true
        )
        settleActiveDurableRun(to: .cancelled, detail: "user_cancelled")
        stopActiveDiscussion()
        finishStreamingMessages(as: .failed)
        activeSpeakerId = nil
        invitedSpeakerIds.removeAll()
        isRunning = false
        roomStateOverride = "已取消"
        appendDivider("已停止")
        appendMessage(
            kind: .system,
            author: "议会",
            body: "本轮议会已停止。",
            systemImage: "stop.circle",
            tint: AmberTheme.accentRed,
            subtitle: "已取消"
        )
        updateDetail(status: "已停止")
        persistTranscript()
        archiveCurrentRoom()
    }

    func showCurrentDetail() {
        activeSheet = .detail(makeDetail(status: isRunning ? selectedMode.runningState : "就绪"))
    }

    func showMembers() {
        activeSheet = .members
    }

    func showSettings() {
        activeSheet = .settings
    }

    func showHistory() {
        guard !isRunning else { return }
        activeSheet = .history
    }

    /// 从「最近讨论」重开一场历史议会,把归档快照还原成只读对话。
    func openArchive(taskId: String) {
        attachmentRoomGeneration &+= 1
        // 切换到只读重放前,先取消节流任务,避免它在 currentTaskId 切换后再次触发写入;
        // stopAndCheckpoint 会对仍在进行的讨论做一次同步检查点。
        // 同时作废材料准备世代,防止「识别中点开历史」后迟到 vision 结果开跑。
        cancelScheduledArchive()
        invalidateMaterialsPreparation(showCancelledMessage: false)
        clearPendingMaterials()
        pendingSourceMaterials = nil
        pendingResearchObjective = nil
        pendingObjective = ""
        guard var room = archiveStore.load(taskId: taskId) else { return }
        stopAndCheckpointActiveDiscussion()
        if let checkpointedRoom = archiveStore.load(taskId: taskId) {
            room = checkpointedRoom
        }
        isRunning = false
        isReplay = true
        currentTaskId = taskId
        currentObjective = room.objective
        currentFinalTopic = room.finalTopic ?? ""
        lastRunObjective = room.objective
        if let mode = CouncilDiscussionMode(rawValue: room.modeRaw) { selectedMode = mode }
        participants = room.participants.map { $0.restored() }
        failedSpeakerIds = Set(room.failedSpeakerIds)
        activeSpeakerId = nil
        invitedSpeakerIds = Set(participants.filter { !$0.isHost }.map(\.id))
        messages = room.messages.map { $0.restored() }
        roomStateOverride = "历史议会 · 只读"
        activeSheet = nil
    }

    /// 退出只读重放,清空房间、恢复默认席位,准备开新议会。
    func startFreshRoom() {
        isReplay = false
        resetRoom()
        refreshSettingsBackedParticipants()
        roomStateOverride = nil
    }

    /// 把当前房间快照按 taskId 归档(供「最近讨论」重开)。在名册/新消息/消息完结/结束等
    /// 检查点调用;不在 per-token 的 updateMessage 上调用,避免每个 token 写一次文件。
    /// - Parameter deferred: true 走离主线程的延迟写入泵(中段检查点);false 同步落盘
    ///   (终态检查点),同步写会 bump 代数,使在途的旧延迟写自动失效。
    private func archiveCurrentRoom(deferred: Bool = false) {
        guard !isReplay, let taskId = currentTaskId, !messages.isEmpty else { return }
        let room = persistedRoom(taskId: taskId)
        if deferred {
            archiveStore.saveDeferred(room)
        } else {
            archiveErrorMessage = archiveStore.save(room)
                ? nil
                : IOSAppLocalization.formatted(
                    "议会已完成，但归档失败：%@",
                    defaultValue: "议会已完成，但归档失败：%@",
                    arguments: [archiveStore.lastErrorDescription ?? IOSAppLocalization.string("未知错误", defaultValue: "未知错误")]
                )
        }
    }

    /// 中段检查点节流:事件密集到达时每个 300ms 窗口最多发起一次延迟写入。
    /// 已有节流任务在等待时直接复用(latest-wins 由 store 的 pendingRoom 保证)。
    private func scheduleArchive() {
        guard !isReplay, currentTaskId != nil, !messages.isEmpty else { return }
        guard archiveThrottleTask == nil else { return }
        archiveThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.archiveThrottleTask = nil
            self?.archiveCurrentRoom(deferred: true)
        }
    }

    private func cancelScheduledArchive() {
        archiveThrottleTask?.cancel()
        archiveThrottleTask = nil
    }

    /// 以指定议题重开一场议会:清空当前画面(含只读重放),再用该议题重新开跑。
    /// 供长按用户消息的「以此为题重开」/「编辑重开」复用。
    func restart(withObjective objective: String) {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isReplay = false
        resetRoom()
        pendingObjective = text
        startPendingDiscussion(researchAllowed: sharedSettings.snapshot.enableWebSearch)
    }

    private func runDiscussion(
        objective: String,
        researchAllowed: Bool,
        discussionID: UUID,
        taskId: String,
        durableRunId: String,
        continuation: IOSCouncilRoomContinuation?,
        sourceMaterials: String? = nil,
        researchObjective: String? = nil
    ) async {
        guard activeDiscussionID == discussionID else { return }
        isRunning = true
        invitedSpeakerIds.removeAll()
        activeSheet = nil
        let didStartDurably = await durableRunAwaiter(.start) { [self] in
            guard let durableRunStore else { return true }
            return (try? await durableRunStore.ensureRunning(
                runId: durableRunId,
                descriptorId: IOSDurableRunStore.Descriptor.council,
                startedAt: Int64(Date().timeIntervalSince1970 * 1_000),
                inputDigest: IOSDurableRunStore.inputDigest(
                    "\(selectedMode.rawValue)\n\(objective)"
                ),
                inputSnapshotRef: "council:\(taskId)"
            )) == true
        }
        guard activeDiscussionID == discussionID, !Task.isCancelled else {
            if didStartDurably {
                _ = try? await durableRunStore?.transitionFromAnyActive(
                    runId: durableRunId,
                    to: .cancelled,
                    detail: "owner_released_before_start"
                )
            }
            return
        }
        guard didStartDurably else {
            appendMessage(
                kind: .system,
                author: "议会",
                body: "无法保存运行状态，本轮议会未启动。",
                systemImage: "exclamationmark.triangle",
                tint: AmberTheme.accentRed,
                subtitle: "启动失败",
                status: .failed
            )
            endBackgroundKeepAlive(for: discussionID)
            isRunning = false
            activeDiscussionID = nil
            activeDurableRunID = nil
            discussionTask = nil
            roomStateOverride = "失败"
            persistTranscript()
            archiveCurrentRoom()
            return
        }
        appendDivider(continuation.map { "追问 · 第 \($0.nextRound) 轮" } ?? selectedMode.openingDivider)
        roomSettingsStore.bootstrapLegacySeatsIfNeeded(
            sharedSettings.savedCouncilSeats,
            currentModelId: currentModelId
        )
        refreshSettingsBackedParticipants()
        guard let currentModel = sharedSettings.snapshot.getCurrentChatModel(),
              let providerSetting = ChatProviderConfiguration.provider(
                  for: currentModel,
                  providers: sharedSettings.snapshot.providers
              ) else {
            appendMessage(
                kind: .system,
                author: "议会",
                body: ChatConfigurationIssue.missingProvider.message,
                systemImage: "exclamationmark.triangle",
                tint: AmberTheme.accentRed,
                subtitle: "配置阻塞",
                status: .failed
            )
            _ = await durableRunAwaiter(.configurationFailure) { [self] in
                guard let durableRunStore else { return true }
                return (try? await durableRunStore.transitionFromAnyActive(
                    runId: durableRunId,
                    to: .failed,
                    detail: ChatConfigurationIssue.missingProvider.message
                )) == true
            }
            guard activeDiscussionID == discussionID, !Task.isCancelled else { return }
            endBackgroundKeepAlive(for: discussionID)
            isRunning = false
            activeDiscussionID = nil
            discussionTask = nil
            roomStateOverride = "失败"
            activeDurableRunID = nil
            persistTranscript()
            return
        }
        let request = IOSCouncilRoomRunRequest(
            taskId: taskId,
            objective: objective,
            mode: selectedMode.runMode,
            settings: roomSettingsStore.settings,
            currentModelId: currentModel.modelId,
            currentModel: currentModel,
            providerSetting: providerSetting,
            providerSettings: sharedSettings.snapshot.providers,
            searchSettings: sharedSettings.snapshot,
            researchConsent: continuation == nil && researchAllowed ? .allowed : .unavailable,
            dynamicSeatGeneration: continuation == nil && roomSettingsStore.dynamicSeatGeneration,
            seatWebSearch: continuation == nil && roomSettingsStore.seatWebSearch,
            continuation: continuation,
            sourceMaterials: sourceMaterials,
            researchObjective: researchObjective
        )
        let summary = await runner.run(request: request, onEvent: { [weak self] event in
            guard let self, self.activeDiscussionID == discussionID else { return }
            self.handle(event)
        })
        guard activeDiscussionID == discussionID else { return }
        if currentTaskId == nil {
            currentTaskId = summary.taskId
        }
        if let finalTopic = summary.finalTopic.trimmedNilIfBlank {
            currentFinalTopic = finalTopic
        }
        _ = await durableRunAwaiter(.completion) { [self] in
            guard let durableRunStore else { return true }
            return (try? await durableRunStore.transitionFromAnyActive(
                runId: durableRunId,
                to: Self.durableStatus(for: summary.status),
                detail: summary.failureReason
            )) == true
        }
        guard activeDiscussionID == discussionID, !Task.isCancelled else { return }
        finishStreamingMessages(as: summary.status == .completed ? .completed : .failed)
        activeSpeakerId = nil
        invitedSpeakerIds.removeAll()
        updateBackgroundProgress(
            completed: summary.status == .completed ? 4 : 3,
            subtitle: summary.status == .completed
                ? IOSAppLocalization.string("议会已完成", defaultValue: "议会已完成")
                : IOSAppLocalization.string(
                    summary.status.title,
                    defaultValue: summary.status.title
                )
        )
        endBackgroundKeepAlive(for: discussionID)
        isRunning = false
        activeDiscussionID = nil
        activeDurableRunID = nil
        discussionTask = nil
        roomStateOverride = summary.status == .completed ? "就绪" : summary.status.title
        updateDetail(status: roomStateOverride ?? "就绪")
        persistTranscript()
        // 终态:取消节流任务 → 排空在途延迟写 → 同步落最终快照。同步写严格最后,
        // 保证「写后立即 load」看到完成态,也不会被旧延迟写覆盖。
        cancelScheduledArchive()
        await archiveStore.flushDeferred()
        archiveCurrentRoom()
    }

    private func appendToken(_ token: String) {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = "\(token) "
        } else if inputText.hasSuffix(" ") {
            inputText += "\(token) "
        } else {
            inputText += " \(token) "
        }
    }

    private var currentConfigurationIssue: ChatConfigurationIssue? {
        guard let model = sharedSettings.snapshot.getCurrentChatModel() else {
            return .missingModel
        }
        let provider = ChatProviderConfiguration.provider(
            for: model,
            providers: sharedSettings.snapshot.providers
        )
        return ChatProviderConfiguration.issue(for: model, provider: provider)
    }

    private func persistedRoom(taskId: String) -> CouncilPersistedRoom {
        CouncilPersistedRoom(
            taskId: taskId,
            objective: currentObjective,
            finalTopic: currentFinalTopic.trimmedNilIfBlank,
            modeRaw: selectedMode.rawValue,
            statusRaw: roomStateOverride ?? "",
            failedSpeakerIds: Array(failedSpeakerIds),
            participants: participants.map(CouncilPersistedParticipant.init),
            messages: messages.map(CouncilPersistedMessage.init),
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
    }

    @discardableResult
    private func appendMessage(
        kind: CouncilMessageKind,
        author: String,
        body: String,
        systemImage: String,
        tint: Color,
        subtitle: String?,
        status: CouncilMessageStatus = .completed
    ) -> UUID {
        let message = CouncilChatMessage(
            kind: kind,
            author: author,
            body: body,
            systemImage: systemImage,
            tint: tint,
            subtitle: subtitle,
            status: status
        )
        messages.append(message)
        updateDetail(status: isRunning ? selectedMode.runningState : "就绪")
        return message.id
    }

    private func appendDivider(_ text: String) {
        messages.append(
            CouncilChatMessage(
                kind: .divider,
                author: "议会",
                body: text,
                systemImage: "circle.grid.cross",
                tint: AmberTheme.muted,
                subtitle: nil
            )
        )
    }

    private func updateMessage(_ id: UUID, body: String, status: CouncilMessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].body = body
        messages[index].status = status
    }

    private func finishStreamingMessages(as status: CouncilMessageStatus) {
        for index in messages.indices where messages[index].status == .speaking {
            messages[index].status = status
        }
    }

    private func handle(_ event: IOSCouncilRoomEvent) {
        switch event {
        case .taskStarted(let id):
            currentTaskId = id
            updateBackgroundProgress(
                completed: 0,
                subtitle: IOSAppLocalization.string("准备议会", defaultValue: "准备议会")
            )
            persistTranscript()
            archiveCurrentRoom()
        case .state(let state):
            roomStateOverride = state
            updateDetail(status: state)
            let lowercased = state.lowercased()
            let completed: Int64
            if state == "就绪" {
                completed = 4
            } else if lowercased.contains("总结") {
                completed = 3
            } else if lowercased.contains("发言") || lowercased.contains("点评") {
                completed = 2
            } else {
                completed = 1
            }
            updateBackgroundProgress(
                completed: completed,
                subtitle: CouncilDisplayCopy.status(state)
            )
        case .roster(let speakers, let activeId, let failedIds):
            participants = speakers.map(CouncilParticipant.init(speaker:))
            activeSpeakerId = activeId
            failedSpeakerIds = failedIds
            invitedSpeakerIds = Set(speakers.filter { !$0.isHost }.map(\.id))
            updateDetail(status: roomStateOverride ?? selectedMode.runningState)
            updateBackgroundProgress(
                completed: 1
            )
            scheduleArchive()
        case .append(let event):
            appendMessage(event)
            scheduleArchive()
        case .updateMessage(let id, let body, let status, let lagAllowance):
            let mapped = CouncilMessageStatus(status)
            activeTailLagAllowance = lagAllowance
            updateMessage(id, body: body, status: mapped)
            // 流式中途也按既有 300ms 窗口归档最新尾部；不做逐 token 同步写，
            // 但进程在席位发言中断时仍能恢复最近一段已接受正文。
            scheduleArchive()
        }
    }

    private func appendMessage(_ event: IOSCouncilRoomMessageEvent) {
        // 新消息开始 = 新的流式上下文：排空收紧值不跨消息残留（与 Chat 语义一致）。
        activeTailLagAllowance = 1
        let participant = event.speakerId.flatMap { id in participants.first(where: { $0.id == id }) }
        let kind = CouncilMessageKind(event.kind)
        let tint = participant?.tint ?? (kind == .system ? AmberTheme.accentIndigo : AmberTheme.muted)
        let image = participant?.systemImage ?? (kind == .divider ? "circle.grid.cross" : "person.3.sequence")
        messages.append(CouncilChatMessage(
            id: event.id,
            kind: kind,
            author: event.author,
            body: event.body,
            systemImage: image,
            tint: tint,
            subtitle: event.subtitle,
            status: CouncilMessageStatus(event.status)
        ))
        updateDetail(status: roomStateOverride ?? (isRunning ? selectedMode.runningState : "就绪"))
    }

    private func roomTranscript(limit: Int) -> String {
        messages
            .suffix(limit)
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\($0.author)] \($0.body)" }
            .joined(separator: "\n\n")
    }

    private func makeContinuationContext() -> IOSCouncilRoomContinuation? {
        guard canContinueCurrentCouncil,
              let taskId = currentTaskId,
              let originalObjective = currentObjective.trimmedNilIfBlank,
              !messages.isEmpty else { return nil }
        let settings = roomSettingsStore.settings.normalized(currentModelId: currentModelId)
        let seatSettings = Dictionary(uniqueKeysWithValues: settings.seats.map { ($0.id, $0) })
        let speakers = participants.map { participant in
            let configuredSeat = seatSettings[participant.id]
            return IOSCouncilRoomSpeaker(
                id: participant.id,
                name: participant.isHost ? "主持人" : participant.displayName,
                rolePrompt: participant.roleDescription,
                modelId: modelId(for: participant),
                providerId: participant.providerId,
                reasoning: participant.isHost
                    ? settings.host.reasoning
                    : configuredSeat?.reasoning ?? .medium,
                prompt: participant.isHost
                    ? settings.host.prompt
                    : configuredSeat?.prompt ?? "",
                isHost: participant.isHost
            )
        }
        guard speakers.contains(where: \.isHost), speakers.contains(where: { !$0.isHost }) else {
            return nil
        }
        return IOSCouncilRoomContinuation(
            taskId: taskId,
            originalObjective: originalObjective,
            finalTopic: currentFinalTopic.trimmedOr(originalObjective),
            priorTranscript: roomTranscript(limit: 80),
            speakers: speakers,
            nextRound: discussionRound + 1
        )
    }

    private var canContinueCurrentCouncil: Bool {
        !isReplay
            && (roomStateOverride == "就绪" || currentFinalTopic.trimmedNilIfBlank != nil)
            && currentTaskId != nil
            && currentObjective.trimmedNilIfBlank != nil
            && hasCouncilMessages
    }

    private func makeDetail(status: String) -> CouncilDiscussionDetail {
        let limits = roomSettingsStore.settings.limits
        let providerName = sharedSettings.resolveCurrentProviderSetting()?.name
            ?? CouncilDisplayCopy.localized("未配置")
        let localizedStatus = selectedMode.runningState == status
            ? selectedMode.localizedRunningState
            : CouncilDisplayCopy.status(status)
        return CouncilDiscussionDetail(
            statusLine: "\(localizedStatus) · \(selectedMode.localizedTitle) · \(CouncilDisplayCopy.localized("主持人")) \(hostDisplayName)",
            objective: currentObjective,
            participantSummary: participants
                .filter { $0.isHost || invitedSpeakerIds.contains($0.id) }
                .map { participant in
                    participant.isHost
                        ? CouncilDisplayCopy.formatted(
                            "主持：%@（%@）",
                            arguments: [participant.displayNameForDisplay, currentModelId]
                        )
                        : CouncilDisplayCopy.formatted(
                            "%@：%@（%@）",
                            arguments: [
                                participant.displayNameForDisplay,
                                CouncilDisplayCopy.localized(participant.roleDescription),
                                modelLabel(for: participant)
                            ]
                        )
                }
                .joined(separator: "\n"),
            budgetSummary: [
                "\(CouncilDisplayCopy.localized("模式"))：\(selectedMode.localizedTitle)",
                IOSAppLocalization.formatted(
                    "最大席位 %lld",
                    defaultValue: "最大席位 %lld",
                    arguments: [Int64(limits.maxSeats)]
                ),
                IOSAppLocalization.formatted(
                    "默认轮数 %lld",
                    defaultValue: "默认轮数 %lld",
                    arguments: [Int64(limits.defaultRounds)]
                ),
                IOSAppLocalization.formatted(
                    "单次模型无输出超时 %llds",
                    defaultValue: "单次模型无输出超时 %llds",
                    arguments: [Int64(limits.seatTimeoutSeconds)]
                ),
                IOSAppLocalization.formatted(
                    "输出预算 %lld",
                    defaultValue: "输出预算 %lld",
                    arguments: [Int64(limits.outputBudgetCharacters)]
                ),
                "\(CouncilDisplayCopy.localized("提供商"))：\(providerName)",
                "\(CouncilDisplayCopy.localized("主持模型"))：\(roomSettingsStore.settings.host.modelId.trimmedOr(currentModelId))"
            ].joined(separator: "\n"),
            transcript: roomTranscript(limit: 80)
        )
    }

    private func updateDetail(status: String) {
        if case .detail = activeSheet {
            activeSheet = .detail(makeDetail(status: status))
        }
    }

    private func modelId(for participant: CouncilParticipant) -> String {
        participant.modelId?.trimmedNilIfBlank ?? currentModelId
    }

    private func modelLabel(for participant: CouncilParticipant) -> String {
        participant.modelId?.trimmedNilIfBlank
            ?? CouncilDisplayCopy.localized(participant.modelHint)
    }

    private static func hostName(for modelId: String) -> String {
        let lowercased = modelId.lowercased()
        if lowercased.contains("claude") { return "Claude" }
        if lowercased.contains("deepseek") { return "DeepSeek" }
        if lowercased.contains("gemini") { return "Gemini" }
        if lowercased.contains("glm") { return "GLM" }
        if lowercased.contains("qwen") { return "Qwen" }
        if lowercased.contains("kimi") { return "Kimi" }
        return "GPT"
    }

    private func refreshSettingsBackedParticipants() {
        roomSettingsStore.bootstrapLegacySeatsIfNeeded(sharedSettings.savedCouncilSeats, currentModelId: currentModelId)
        let settings = roomSettingsStore.settings.normalized(currentModelId: currentModelId)
        let host = IOSCouncilRoomSpeaker(
            id: "host",
            name: "主持人",
            rolePrompt: settings.host.prompt,
            modelId: settings.host.modelId,
            reasoning: settings.host.reasoning,
            prompt: settings.host.prompt,
            isHost: true
        )
        let seats = settings.defaultSeats(currentModelId: currentModelId).map {
            IOSCouncilRoomSpeaker(
                id: $0.id,
                name: $0.name,
                rolePrompt: $0.rolePrompt,
                modelId: $0.modelId,
                reasoning: $0.reasoning,
                prompt: $0.prompt,
                isHost: false
            )
        }
        participants = ([host] + seats).map(CouncilParticipant.init(speaker:))
    }

    private func resetRoom() {
        attachmentRoomGeneration &+= 1
        stopAndCheckpointActiveDiscussion()
        // 取消运行中的议会后,被 cancel 的 async 任务不会再走到末尾的 isRunning=false,
        // 这里显式复位,确保「重开」后输入框/发送键立刻回到就绪态。
        isRunning = false
        activeSpeakerId = nil
        invitedSpeakerIds.removeAll()
        failedSpeakerIds.removeAll()
        currentTaskId = nil
        roomStateOverride = nil
        currentObjective = ""
        currentFinalTopic = ""
        invalidateMaterialsPreparation(showCancelledMessage: false)
        clearPendingMaterials()
        attachmentErrorMessage = nil
        pendingSourceMaterials = nil
        pendingResearchObjective = nil
        pendingObjective = ""
        // 重开 = 把画面清成真正空白(和首次进入议会一致:只剩「输入议题开始」占位),
        // 不再自动发一条「已重新开始」系统消息(画蛇添足)。
        messages = []
        activeTailLagAllowance = 1
        // 重新开始即清空历史(存盘也同步为空白开场),避免退出后又载回旧 transcript。
        persistTranscript()
        refreshSettingsBackedParticipants()
    }

    /// Start a materials prep epoch; cancels any previous prep task.
    @discardableResult
    private func beginMaterialsPreparation(status: String) -> UInt64 {
        materialsPrepGeneration &+= 1
        materialsPreparationTask?.cancel()
        materialsPreparationTask = nil
        isPreparingMaterials = true
        materialsPreparationStatus = status
        attachmentErrorMessage = nil
        beginMaterialsKeepAlive()
        return materialsPrepGeneration
    }

    /// Clear preparing UI only if this completion still owns the current generation.
    @discardableResult
    private func finishMaterialsPreparation(ifGeneration generation: UInt64) -> Bool {
        guard materialsPrepGeneration == generation else { return false }
        materialsPreparationTask = nil
        isPreparingMaterials = false
        materialsPreparationStatus = ""
        endMaterialsKeepAlive()
        return true
    }

    private func invalidateMaterialsPreparation(showCancelledMessage: Bool) {
        materialsPrepGeneration &+= 1
        materialsPreparationTask?.cancel()
        materialsPreparationTask = nil
        isPreparingMaterials = false
        materialsPreparationStatus = ""
        endMaterialsKeepAlive()
        if showCancelledMessage {
            attachmentErrorMessage = IOSAppLocalization.string(
                "已取消材料解析",
                defaultValue: "已取消材料解析"
            )
        }
    }

    private func materialsKeepAliveLeaseId() -> String {
        "council-materials"
    }

    private func beginMaterialsKeepAlive() {
        let expire: () -> Void = { [weak self] in
            self?.invalidateMaterialsPreparation(showCancelledMessage: false)
        }
        BackgroundGenerationKeepAlive.shared.begin(
            materialsKeepAliveLeaseId(),
            title: IOSAppLocalization.string(
                "Amber 议会准备中",
                defaultValue: "Amber 议会准备中"
            ),
            subtitle: materialsPreparationStatus.isEmpty
                ? IOSAppLocalization.string("解析材料", defaultValue: "解析材料")
                : materialsPreparationStatus,
            onExpire: expire,
            onSystemTaskExpiration: expire
        )
    }

    private func endMaterialsKeepAlive() {
        BackgroundGenerationKeepAlive.shared.end(materialsKeepAliveLeaseId())
    }

    private func stopAndCheckpointActiveDiscussion(
        taskStatus: IOSAdvancedTaskStatus = .cancelled,
        terminalMessage: String? = nil
    ) {
        // 取消即终止路径:无论是否要 checkpoint 都先取消节流任务,避免切走后再次写入。
        cancelScheduledArchive()
        let shouldCheckpoint = activeDiscussionID != nil || isRunning
        let discussionID = activeDiscussionID
        if shouldCheckpoint {
            runner.markActiveTaskTerminal(
                taskId: currentTaskId,
                status: taskStatus,
                summary: terminalMessage ?? taskStatus.title,
                retryable: taskStatus == .interrupted || taskStatus == .cancelled
            )
            settleActiveDurableRun(
                to: Self.durableStatus(for: taskStatus),
                detail: terminalMessage ?? taskStatus.title
            )
        }
        // 到期/切换页时先把取消后的内存尾部写入快照，再释放后台执行权；系统
        // 可能在租约结束后立即终止进程，不能让 archive 落盘排在 lease 之后。
        stopActiveDiscussion(releaseBackgroundLease: false)
        guard shouldCheckpoint else { return }

        finishStreamingMessages(as: .failed)
        activeSpeakerId = nil
        invitedSpeakerIds.removeAll()
        isRunning = false
        roomStateOverride = taskStatus.title
        updateDetail(status: taskStatus.title)
        if let terminalMessage {
            appendMessage(
                kind: .system,
                author: "议会",
                body: terminalMessage,
                systemImage: "pause.circle",
                tint: AmberTheme.accentRed,
                subtitle: taskStatus.title,
                status: .failed
            )
        }
        persistTranscript()
        archiveCurrentRoom()
        endBackgroundKeepAlive(for: discussionID)
    }

    private func stopActiveDiscussion(releaseBackgroundLease: Bool = true) {
        discussionTask?.cancel()
        // The concrete streamer synchronously drains accepted FIFO chunks here.
        // Keep ownership valid until that exact tail has reached the current bubble.
        runner.cancel()
        let discussionID = activeDiscussionID
        keepAliveReleaseTask?.cancel()
        keepAliveReleaseTask = nil
        if releaseBackgroundLease {
            endBackgroundKeepAlive(for: discussionID)
        }
        activeDiscussionID = nil
        activeDurableRunID = nil
        discussionTask = nil
    }

    private func settleActiveDurableRun(to status: AgentRunStatus, detail: String?) {
        guard let runId = activeDurableRunID, let durableRunStore else { return }
        Task { [durableRunStore] in
            _ = try? await durableRunStore.transitionFromAnyActive(
                runId: runId,
                to: status,
                detail: detail
            )
        }
    }

    private static func durableStatus(for status: IOSAdvancedTaskStatus) -> AgentRunStatus {
        switch status {
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case .interrupted, .timedOut:
            .interrupted
        case .failed:
            .failed
        case .queued, .running, .approvalRequired:
            .interrupted
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

