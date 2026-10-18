import SwiftUI

struct NovelWritingContextSheet: View {
    @Environment(\.dismiss) private var dismiss

    let workspace: NovelCreationViewModel
    let session: NovelSessionViewModel
    let sharedSettings: any IOSSettingsSnapshotSource
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity
    let userText: String
    let onEditWritingRequirements: () -> Void
    let onEditPolishPreference: () -> Void
    let onApply: (NovelInjectionOverrides, Int) -> Void

    @State private var selectedTab = NovelWritingContextTab.preferences
    @State private var budgetTokens: Int
    @State private var materialChoices: [NovelMaterialID: NovelWritingMaterialChoice]
    @State private var previewSignature: String?
    @State private var selectedMode: NovelCollaborationMode
    @State private var writingContextFields: NovelWritingContextFieldState
    @State private var planDraftOwner: NovelSessionBinding?
    @State private var ghostwriteReadinessCache = NovelGhostwriteReadinessIssuesCache()
    @State private var modeSwitchMessage: String?
    @State private var planMessage: String?
    @State private var isPresentingGhostwriteRevision = false
    @State private var planMessageIsError = false
    @State private var arcMessage: String?
    @State private var arcMessageIsError = false
    @State private var confirmClearPlan = false
    @State private var confirmClearArc = false
    @State private var confirmCancelGhostwriteBatch = false
    @State private var isSavingCollaborationMode = false
    @State private var savingChapterPlanStatus: NovelChapterPlanStatus?
    @State private var savingChapterPlanRevision: Int?
    @State private var chapterPlanSaveTask: Task<Bool, Never>?
    @State private var isSavingUpcomingArc = false
    /// 根据前文生成草稿本章计划（模型调用中）。
    @State private var isProposingPlanDraft = false

    init(
        workspace: NovelCreationViewModel,
        session: NovelSessionViewModel,
        sharedSettings: any IOSSettingsSnapshotSource,
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity,
        userText: String,
        overrides: NovelInjectionOverrides,
        budgetTokens: Int,
        onEditWritingRequirements: @escaping () -> Void,
        onEditPolishPreference: @escaping () -> Void,
        onApply: @escaping (NovelInjectionOverrides, Int) -> Void
    ) {
        self.workspace = workspace
        self.session = session
        self.sharedSettings = sharedSettings
        self.mode = mode
        self.granularity = granularity
        self.userText = userText
        self.onEditWritingRequirements = onEditWritingRequirements
        self.onEditPolishPreference = onEditPolishPreference
        self.onApply = onApply
        self._budgetTokens = State(initialValue: budgetTokens)
        var choices: [NovelMaterialID: NovelWritingMaterialChoice] = [:]
        for materialID in overrides.forceIncludeMaterialIDs {
            choices[materialID] = .include
        }
        for materialID in overrides.forceExcludeMaterialIDs {
            choices[materialID] = .exclude
        }
        self._materialChoices = State(initialValue: choices)
        self._previewSignature = State(initialValue: nil)
        let existingMode = workspace.projectSnapshot?.project.collaborationMode ?? .cocreation
        self._selectedMode = State(initialValue: existingMode)
        let existingPlan = workspace.selectedBranchID.flatMap {
            workspace.projectSnapshot?.chapterPlan(for: $0)
        }
        let existingArc = workspace.selectedBranchID.flatMap {
            workspace.projectSnapshot?.upcomingArc(for: $0)
        }
        let draftOwner = workspace.selectedProjectID.flatMap { projectID in
            workspace.selectedBranchID.map { branchID in
                NovelSessionBinding(projectID: projectID, branchID: branchID)
            }
        }
        let retainedDraft = draftOwner.flatMap {
            workspace.chapterPlanDraft(projectID: $0.projectID, branchID: $0.branchID)
        }
        self._writingContextFields = State(
            initialValue: NovelWritingContextFieldState(plan: existingPlan, arc: existingArc, retainedDraft: retainedDraft)
        )
        self._planDraftOwner = State(initialValue: draftOwner)
        self._planMessage = State(initialValue: retainedDraft != nil ? "已恢复未保存的本章计划草稿，请核对后保存。" : nil)
        self._planMessageIsError = State(initialValue: retainedDraft != nil)
        self._modeSwitchMessage = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("项目控制", selection: $selectedTab) {
                    ForEach(NovelWritingContextTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch selectedTab {
                case .preferences:
                    preferencesList
                case .context:
                    NovelWritingInjectionOverview(
                        workspace: workspace,
                        mode: mode,
                        granularity: granularity,
                        budgetTokens: $budgetTokens,
                        materialChoices: materialChoices,
                        hasMatchingPreview: matchingPreview != nil
                    )
                }
            }
            .background(AmberTheme.background)
            .navigationTitle("项目控制")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NovelWritingContextRoute.self) { route in
                switch route {
                case .materials(let category):
                    NovelWritingMaterialChoicesView(
                        workspace: workspace,
                        category: category,
                        materialChoices: $materialChoices,
                        onChoiceChanged: { updatedOverrides in
                            onApply(updatedOverrides, budgetTokens)
                        }
                    )
                case .preview:
                    NovelWritingContextPreviewView(preview: matchingPreview)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        IOSAppLocalization.string(
                            NovelGhostwriteSheetChrome.leadingActionTitle(
                                canAbandonBatch: session.canCancelGhostwriteBatch
                            ),
                            defaultValue: NovelGhostwriteSheetChrome.leadingActionTitle(
                                canAbandonBatch: session.canCancelGhostwriteBatch
                            )
                        )
                    ) {
                        if session.canCancelGhostwriteBatch {
                            confirmCancelGhostwriteBatch = true
                        } else {
                            NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if collaborationMode == .ghostwrite {
                        // 顶栏只放短词；长文案在下方大按钮。
                        Button(toolbarGhostwriteActionTitle) {
                            performToolbarGhostwriteAction()
                        }
                        .lineLimit(1)
                        .disabled(toolbarGhostwriteActionDisabled)
                    } else {
                        Button("预览") {
                            NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
                                preview()
                            }
                        }
                        .disabled(!canPreview || workspace.isPerforming)
                    }
                }
            }
            .overlay {
                if workspace.isPerforming,
                   !session.isGhostwriting,
                   !isSavingCollaborationMode,
                   savingChapterPlanStatus == nil,
                   !isSavingUpcomingArc {
                    ProgressView()
                }
            }
        }
        // 收起面板不等于停代笔。代笔进行中也必须能从滑杆下拉关闭。
        .onDisappear {
            // 面板关闭（下滑或切走）时兜底：计划有未保存改动 → 存草稿；
            // 预算兜底回写（滑块拖动中不触发，关闭时落定）。
            // 资料覆盖已在勾选时即时回写，无需重复。
            // 正在根据前文生成时不写本地 dirty，避免盖掉模型刚落盘的草稿。
            NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
                if writingContextFields.planFieldsDirty, !isProposingPlanDraft {
                    let draftRevision = writingContextFields.planEditRevision
                    let draftOutlinePlacement = writingContextFields.planPlacement
                    let draftGoalAndConflict = writingContextFields.planGoal
                    let draftMustHappen = planLines(from: writingContextFields.planMustHappen)
                    let draftMustNotHappen = planLines(from: writingContextFields.planMustNotHappen)
                    let draftEndingHook = writingContextFields.planEndingHook
                    let draftVisibleFacts = planLines(from: writingContextFields.planVisibleFacts)
                    let inFlightPlanSave = chapterPlanSaveTask
                    let inFlightPlanRevision = savingChapterPlanRevision
                    let draftOwner = planDraftOwner
                    let draft = NovelChapterPlanDraft(
                        outlinePlacement: draftOutlinePlacement, goalAndConflict: draftGoalAndConflict,
                        mustHappen: draftMustHappen, mustNotHappen: draftMustNotHappen,
                        endingHook: draftEndingHook, visibleFacts: draftVisibleFacts
                    )
                    if let draftOwner {
                        workspace.retainChapterPlanDraft(draft, projectID: draftOwner.projectID, branchID: draftOwner.branchID)
                    }
                    Task { @MainActor [workspace, inFlightPlanSave, draftOwner] in
                        var shouldSaveDraft = true
                        if let inFlightPlanSave {
                            let priorSaveSucceeded = await inFlightPlanSave.value
                            shouldSaveDraft = !priorSaveSucceeded || inFlightPlanRevision != draftRevision
                        }
                        guard let draftOwner else {
                            workspace.errorMessage = "本章计划缺少原项目信息，草稿未能保存。"
                            return
                        }
                        guard shouldSaveDraft else {
                            workspace.clearChapterPlanDraft(ifMatching: draft, projectID: draftOwner.projectID, branchID: draftOwner.branchID)
                            return
                        }
                        let saved = await workspace.saveChapterPlanDraft(
                            projectID: draftOwner.projectID,
                            branchID: draftOwner.branchID,
                            outlinePlacement: draftOutlinePlacement,
                            goalAndConflict: draftGoalAndConflict,
                            mustHappen: draftMustHappen,
                            mustNotHappen: draftMustNotHappen,
                            endingHook: draftEndingHook,
                            visibleFacts: draftVisibleFacts,
                            retainingDraft: false
                        )
                        if !saved {
                            if workspace.errorMessage == nil || workspace.errorMessage?.isEmpty == true {
                                workspace.errorMessage = "本章计划保存失败，草稿也未能保存。"
                            }
                        }
                    }
                }
                onApply(overrides, budgetTokens)
            }
        }
        .confirmationDialog(
            "清除本章计划？",
            isPresented: $confirmClearPlan,
            titleVisibility: .visible
        ) {
            Button("清除计划", role: .destructive) {
                NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
                    Task { await clearChapterPlan() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后要重新写好并确认，才能继续代笔写整章。")
        }
        .confirmationDialog(
            "清除往后几章的备注？",
            isPresented: $confirmClearArc,
            titleVisibility: .visible
        ) {
            Button("清除备注", role: .destructive) {
                NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
                    Task { await clearUpcomingArc() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后，写整章时就不再参考这些备注。")
        }
        .confirmationDialog(
            "结束本批代笔？",
            isPresented: $confirmCancelGhostwriteBatch,
            titleVisibility: .visible
        ) {
            Button("结束本批", role: .destructive) {
                session.cancelGhostwriteBatch()
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("已收录的章节会留在正文里。未写完的章会停掉，下次代笔算新的一批。")
        }
        .sheet(isPresented: $isPresentingGhostwriteRevision) {
            let progress = session.ghostwriteProgress
            let receipt = progress?.lastFailureReceipt
            let recommendedBrief = receipt?.recommendedRevisionBrief() ?? ""
            NovelGhostwriteRevisionSheet(
                recommendedBrief: recommendedBrief,
                // 中断摘要用审稿意见，不把离页/重启元信息塞进「原因」。
                detail: {
                    let summary = receipt?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let summary, !summary.isEmpty { return summary }
                    let missing = receipt?.missingMustHappen.filter {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    } ?? []
                    if !missing.isEmpty {
                        return "须补写：\n" + missing.map { "· \($0)" }.joined(separator: "\n")
                    }
                    return nil
                }(),
                strategies: progress?.pauseReason == .blockingContinuity
                    ? NovelGhostwriteRevisionStrategy.continuityOptions(
                        recommendedBrief: recommendedBrief
                    )
                    : [],
                onCancel: { isPresentingGhostwriteRevision = false },
                onStart: { brief in
                    let started = session.startGhostwriteRevision(brief: brief)
                    if started {
                        isPresentingGhostwriteRevision = false
                    }
                    return started
                }
            )
        }
    }

    private var preferencesList: some View {
        let blockers = ghostwriteSwitchBlockers
        return List {
            Section {
                HStack(spacing: 8) {
                    Picker("创作模式", selection: $selectedMode) {
                        ForEach(NovelCollaborationMode.allCases, id: \.self) { mode in
                            Text(IOSAppLocalization.string(
                                mode.displayName,
                                defaultValue: mode.displayName
                            )).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(
                        ((!workspace.canMutate || workspace.isPerforming) && !isSavingCollaborationMode)
                            || session.isGhostwriting
                    )
                    .onChange(of: selectedMode) { _, newMode in
                        selectCollaborationMode(newMode)
                    }
                    .onChange(of: persistedCollaborationMode) { _, newMode in
                        if !isSavingCollaborationMode, selectedMode != newMode {
                            selectedMode = newMode
                        }
                    }

                    ZStack {
                        if isSavingCollaborationMode {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                }

                if session.isGhostwriting {
                    Text("代笔进行中，暂停后可切回共创。")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                }

                if let modeSwitchMessage, !modeSwitchMessage.isEmpty {
                    Label(modeSwitchMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.accentRed)
                }

                if collaborationMode == .cocreation, !blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("切入代笔还需：")
                            .font(.footnote.weight(.semibold))
                        ForEach(blockers, id: \.self) { issue in
                            Text("· \(issue.displayName)")
                                .font(.footnote)
                        }
                    }
                    .foregroundStyle(AmberTheme.muted)
                }
            } header: {
                Text("创作模式")
            } footer: {
                Text(modeSectionFooter)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if collaborationMode == .ghostwrite {
                NovelGhostwriteProgressBoard(
                    progress: session.ghostwriteProgress,
                    planStatusLabel: planStatusLabel,
                    reviewModelLabel: reviewModelLabel,
                    upcomingArcStatusLabel: upcomingArcStatusLabel
                )

                Section {
                    Label("每章收录前都会检查连续性硬伤", systemImage: "checkmark.shield")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.foreground2)

                    Stepper(
                        value: Binding(
                            get: { ghostwriteDisplayedTargetCount },
                            set: { session.ghostwriteTargetChapterCount = NovelGhostwriteBatch.clamp($0) }
                        ),
                        in: NovelGhostwriteBatch.minChapterCount...NovelGhostwriteBatch.maxChapterCount
                    ) {
                        Text(
                            shouldShowContinueGhostwrite
                                ? IOSAppLocalization.formatted(
                                    "本批固定 %lld 章",
                                    defaultValue: "本批固定 %lld 章",
                                    arguments: [ghostwriteDisplayedTargetCount]
                                )
                                : IOSAppLocalization.formatted(
                                    "本批目标 %lld 章",
                                    defaultValue: "本批目标 %lld 章",
                                    arguments: [ghostwriteDisplayedTargetCount]
                                )
                        )
                    }
                    // 进行中或本批未终态续跑：N 已锁定，禁止改 Stepper 误导用户。
                    .disabled(
                        session.isGhostwriting
                            || workspace.isPerforming
                            || shouldShowContinueGhostwrite
                    )
                    .accessibilityLabel("本批目标章数")
                    .accessibilityValue(IOSAppLocalization.formatted(
                        "%lld 章",
                        defaultValue: "%lld 章",
                        arguments: [ghostwriteDisplayedTargetCount]
                    ))

                    if !session.isGhostwriting,
                       let blocker = session.ghostwriteBlocker,
                       !session.canStartGhostwriteChapter {
                        Text(session.ghostwriteReadinessIssue?.displayName ?? blocker.displayName)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                    }

                    // 启动/续跑失败等操作错误：进度区未必有对应 detail，这里兜底露出。
                    // 与红色 detail 相同则不重复渲染。
                    if let operationError = session.operationErrorMessage,
                       !operationError.isEmpty,
                       operationError != session.ghostwriteProgress?.detailMessage,
                       operationError != session.ghostwriteReadinessIssue?.displayName,
                       operationError != session.ghostwriteBlocker?.displayName {
                        Label(operationError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.accentRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Group {
                        if session.isGhostwriting {
                            Button {
                                session.pauseGhostwrite()
                            } label: {
                                Text("暂停")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .contentShape(Rectangle())
                        } else if session.ghostwriteProgress?.pauseReason == .planProposedForNewBatch {
                            // 与右上角按钮同文案同动作。
                            Button {
                                _ = session.continueGhostwriteChapter()
                            } label: {
                                Text("确认计划，开始写")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .contentShape(Rectangle())
                            .disabled(!session.canStartGhostwriteChapter)
                        } else if shouldShowContinueGhostwrite {
                            if session.ghostwriteProgress?.shouldOfferRevisionSheet == true {
                                Button {
                                    isPresentingGhostwriteRevision = true
                                } label: {
                                    Text("按审稿意见润修")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .contentShape(Rectangle())
                                .disabled(!session.canStartGhostwriteChapter)

                                if session.ghostwriteProgress?.pauseReason != .blockingContinuity {
                                    Button {
                                        _ = session.continueGhostwriteChapter()
                                    } label: {
                                        Text(continueGhostwriteButtonTitle)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .contentShape(Rectangle())
                                    .disabled(!session.canStartGhostwriteChapter)
                                }
                            } else {
                                Button {
                                    _ = session.continueGhostwriteChapter()
                                } label: {
                                    Text(continueGhostwriteButtonTitle)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .contentShape(Rectangle())
                                .disabled(!session.canStartGhostwriteChapter)
                            }
                        } else {
                            let n = NovelGhostwriteBatch.clamp(session.ghostwriteTargetChapterCount)
                            let isStartingNextBatch = session.ghostwriteProgress?.pauseReason == .batchCompleted
                                || session.ghostwriteProgress?.pauseReason == .chapterCompleted
                            Button {
                                _ = session.startGhostwriteChapter(targetChapterCount: n)
                            } label: {
                                Text(
                                    isStartingNextBatch
                                        ? (n == 1
                                            ? IOSAppLocalization.string("代笔下一章", defaultValue: "代笔下一章")
                                            : IOSAppLocalization.formatted(
                                                "代笔下一批 · %lld 章",
                                                defaultValue: "代笔下一批 · %lld 章",
                                                arguments: [n]
                                            ))
                                        : (n == 1
                                            ? IOSAppLocalization.string("开始代笔本章", defaultValue: "开始代笔本章")
                                            : IOSAppLocalization.formatted(
                                                "开始代笔 · %lld 章",
                                                defaultValue: "开始代笔 · %lld 章",
                                                arguments: [n]
                                            ))
                                )
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .contentShape(Rectangle())
                            .disabled(!session.canStartGhostwriteChapter)
                        }
                    }
                } header: {
                    Text(ghostwriteAdvanceSectionTitle)
                } footer: {
                    Text(ghostwriteAdvanceSectionFooter)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("计划状态", value: planStatusLabel)

                    NovelWritingContextPlacementFieldRow(
                        fields: writingContextFields,
                        isEnabled: canEditChapterPlan
                    )
                    NovelWritingContextFieldRow(
                        title: "目标与冲突",
                        fields: writingContextFields,
                        field: .goal,
                        placeholder: "本章要解决什么",
                        isEnabled: canEditChapterPlan,
                        minHeight: 88
                    )
                    NovelWritingContextFieldRow(
                        title: "必发生（每行一条）",
                        fields: writingContextFields,
                        field: .mustHappen,
                        placeholder: "至少一条",
                        isEnabled: canEditChapterPlan,
                        minHeight: 72
                    )
                    NovelWritingContextFieldRow(
                        title: "禁止发生（每行一条）",
                        fields: writingContextFields,
                        field: .mustNotHappen,
                        placeholder: "可空",
                        isEnabled: canEditChapterPlan,
                        minHeight: 64
                    )
                    NovelWritingContextFieldRow(
                        title: "章末钩子",
                        fields: writingContextFields,
                        field: .endingHook,
                        placeholder: "可空",
                        isEnabled: canEditChapterPlan,
                        minHeight: 56
                    )
                    NovelWritingContextFieldRow(
                        title: "POV 可见要点（每行一条）",
                        fields: writingContextFields,
                        field: .visibleFacts,
                        placeholder: "可空",
                        isEnabled: canEditChapterPlan,
                        minHeight: 64
                    )

                if let planMessage, !planMessage.isEmpty {
                    Label(
                        planMessage,
                        systemImage: planMessageIsError
                            ? "exclamationmark.triangle"
                            : "checkmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(planMessageIsError ? AmberTheme.accentRed : AmberTheme.muted)
                }

                if canShowProposePlanDraft {
                    Button {
                        Task { await proposeChapterPlanDraft() }
                    } label: {
                        HStack(spacing: 8) {
                            if isProposingPlanDraft {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(proposePlanDraftButtonTitle)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .contentShape(Rectangle())
                    .disabled(!canProposePlanDraft)
                    .accessibilityLabel(proposePlanDraftButtonTitle)
                }

                HStack(spacing: 12) {
                    Button {
                        commitPlanFieldsThen {
                            saveChapterPlan(status: .draft)
                        }
                    } label: {
                        ZStack {
                            Text("保存草稿")
                                .opacity(savingChapterPlanStatus == .draft ? 0 : 1)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if savingChapterPlanStatus == .draft {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!canEditChapterPlan || isProposingPlanDraft || savingChapterPlanStatus != nil)

                    Button {
                        commitPlanFieldsThen {
                            saveChapterPlan(status: .confirmed)
                        }
                    } label: {
                        ZStack {
                            Text("确认计划")
                                .opacity(savingChapterPlanStatus == .confirmed ? 0 : 1)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if savingChapterPlanStatus == .confirmed {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!canEditChapterPlan || isProposingPlanDraft || savingChapterPlanStatus != nil)

                    Spacer(minLength: 0)

                    if currentChapterPlan != nil {
                        Button("清除", role: .destructive) {
                            confirmClearPlan = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(!canEditChapterPlan || isProposingPlanDraft || savingChapterPlanStatus != nil)
                    }
                }
            } header: {
                Text("本章计划")
            } footer: {
                Text(chapterPlanSectionFooter)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                NovelWritingContextFieldRow(
                    title: "后面几章想往哪走（每行一条）",
                    fields: writingContextFields,
                    field: .upcomingArc,
                    placeholder: "例如：使者身份曝光",
                    isEnabled: canEditUpcomingArc,
                    minHeight: 96
                )

                if let arcMessage, !arcMessage.isEmpty {
                    Label(
                        arcMessage,
                        systemImage: arcMessageIsError
                            ? "exclamationmark.triangle"
                            : "checkmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(arcMessageIsError ? AmberTheme.accentRed : AmberTheme.muted)
                }

                HStack(spacing: 12) {
                    Button {
                        commitPlanFieldsThen {
                            saveUpcomingArc()
                        }
                    } label: {
                        ZStack {
                            Text("保存")
                                .opacity(isSavingUpcomingArc ? 0 : 1)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if isSavingUpcomingArc {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!canEditUpcomingArc || isSavingUpcomingArc)

                    Spacer(minLength: 0)

                    if currentUpcomingArc != nil {
                        Button("清除", role: .destructive) {
                            confirmClearArc = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(!canEditUpcomingArc || isSavingUpcomingArc)
                    }
                }
            } header: {
                Text("往后几章")
            } footer: {
                Text(IOSAppLocalization.formatted(
                    "最多 %lld 条备注；写整章时会参考，不替代本章计划。",
                    defaultValue: "最多 %lld 条备注；写整章时会参考，不替代本章计划。",
                    arguments: [NovelUpcomingArcRecord.maxBeats]
                ))
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("写作偏好") {
                Button {
                    applyDraftBeforeTransition(onEditWritingRequirements)
                } label: {
                    NovelSettingsRow(
                        systemImage: "text.badge.checkmark",
                        title: "写作要求",
                        value: hasWritingRequirements ? "已设置" : "未设置",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canMutate)

                Button {
                    applyDraftBeforeTransition(onEditPolishPreference)
                } label: {
                    NovelSettingsRow(
                        systemImage: "wand.and.sparkles",
                        title: "整章润色偏好",
                        value: hasPolishPreference ? "已设置" : "未设置",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canMutate)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
        .onChange(of: chapterPlanFieldSyncToken) { _, newToken in
            // Local dirty edits win over snapshot echo. Also never clobber IME.
            if writingContextFields.planFieldsDirty || writingContextFields.fieldBank.hasAnyMarkedText
                || NovelTextInputCommitter.hasMarkedText() {
                if newToken == "none", !writingContextFields.fieldBank.hasAnyMarkedText,
                   let owner = planDraftOwner,
                   workspace.chapterPlanDraft(projectID: owner.projectID, branchID: owner.branchID) == nil {
                    // Plan cleared externally while we were not composing.
                    reloadPlanFieldsFromWorkspace()
                }
                return
            }
            reloadPlanFieldsFromWorkspace()
        }
        .onChange(of: upcomingArcFieldSyncToken) { _, newToken in
            if writingContextFields.arcFieldsDirty || writingContextFields.fieldBank.hasAnyMarkedText
                || NovelTextInputCommitter.hasMarkedText() {
                if newToken == "none", !writingContextFields.fieldBank.hasAnyMarkedText {
                    reloadUpcomingArcFromWorkspace()
                }
                return
            }
            reloadUpcomingArcFromWorkspace()
        }
    }

    private func commitPlanFieldsThen(_ action: @escaping @MainActor () -> Void) {
        // Synchronous UIKit flush so save reads the last marked glyphs.
        NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank, action)
    }

    private var persistedCollaborationMode: NovelCollaborationMode {
        workspace.projectSnapshot?.project.collaborationMode ?? .cocreation
    }

    private var collaborationMode: NovelCollaborationMode { selectedMode }

    /// Workspace 合同身份变化时（清除 / 换稿）驱动本地字段回填。
    private var chapterPlanFieldSyncToken: String {
        guard let plan = currentChapterPlan else { return "none" }
        return "\(plan.id.rawValue.uuidString)|\(plan.contentDigest)|\(plan.status.rawValue)"
    }

    private var modeSectionFooter: String {
        var parts = [IOSAppLocalization.string(
            collaborationMode.shortSummary,
            defaultValue: collaborationMode.shortSummary
        )]
        if collaborationMode == .ghostwrite {
            if session.ghostwriteProgress?.pauseReason == .planProposedForNewBatch {
                parts.append(IOSAppLocalization.string(
                    "已自动拟定下一章计划。确认后开始写，批内后续章节全自动连写。",
                    defaultValue: "已自动拟定下一章计划。确认后开始写，批内后续章节全自动连写。"
                ))
            } else if shouldShowContinueGhostwrite {
                parts.append(IOSAppLocalization.string(
                    "本批未完成：可继续；质量问题会自动改写几次，仍不过再停住。",
                    defaultValue: "本批未完成：可继续；质量问题会自动改写几次，仍不过再停住。"
                ))
            } else if session.isGhostwriting {
                parts.append(IOSAppLocalization.string(
                    "代笔进行中，可在下方暂停。",
                    defaultValue: "代笔进行中，可在下方暂停。"
                ))
            } else if session.ghostwriteProgress?.pauseReason == .batchCompleted
                        || session.ghostwriteProgress?.pauseReason == .chapterCompleted {
                parts.append(IOSAppLocalization.string(
                    "上一批已完成。在下方「代笔」区点按钮开始下一批。",
                    defaultValue: "上一批已完成。在下方「代笔」区点按钮开始下一批。"
                ))
            } else {
                parts.append(IOSAppLocalization.string(
                    "可用「开始代笔」按批自动写整章并审核收录；也可以继续自己点。",
                    defaultValue: "可用「开始代笔」按批自动写整章并审核收录；也可以继续自己点。"
                ))
            }
        }
        return parts.joined(separator: " ")
    }

    /// 与 `NovelGhostwriteProgress.shouldContinueSameBatch` 一致：完批/取消后显示「开始」。
    private var shouldShowContinueGhostwrite: Bool {
        guard let progress = session.ghostwriteProgress else { return false }
        return progress.shouldContinueSameBatch
    }

    private var ghostwriteAdvanceSectionTitle: String {
        if session.isGhostwriting {
            return IOSAppLocalization.string("代笔进行中", defaultValue: "代笔进行中")
        }
        // planProposedForNewBatch 优先级在 shouldShowContinueGhostwrite 之前，
        // 与 toolbar 按钮分支顺序一致，避免文案矛盾。
        if session.ghostwriteProgress?.pauseReason == .planProposedForNewBatch {
            return IOSAppLocalization.string("确认计划后开始写", defaultValue: "确认计划后开始写")
        }
        if shouldShowContinueGhostwrite {
            return IOSAppLocalization.string("继续本批代笔", defaultValue: "继续本批代笔")
        }
        // 完批/完章后：用户看到的应是「下一批」而非看起来像初始的「开始代笔」。
        if session.ghostwriteProgress?.pauseReason == .batchCompleted {
            return IOSAppLocalization.string("开启下一批代笔", defaultValue: "开启下一批代笔")
        }
        if session.ghostwriteProgress?.pauseReason == .chapterCompleted {
            return IOSAppLocalization.string("代笔下一章", defaultValue: "代笔下一章")
        }
        return IOSAppLocalization.string("开始代笔", defaultValue: "开始代笔")
    }

    private var ghostwriteAdvanceSectionFooter: String {
        if session.ghostwriteProgress?.pauseReason == .planProposedForNewBatch {
            return IOSAppLocalization.string(
                "已自动拟定下一章计划。确认后开始写本章，批内后续章节全自动连写。",
                defaultValue: "已自动拟定下一章计划。确认后开始写本章，批内后续章节全自动连写。"
            )
        }
        if shouldShowContinueGhostwrite {
            if session.ghostwriteProgress?.pauseReason == .backgroundInterrupted {
                return IOSAppLocalization.string(
                    "系统暂停了后台代笔，回到前台会自动继续；若仍停在这里，可手动继续本批。",
                    defaultValue: "系统暂停了后台代笔，回到前台会自动继续；若仍停在这里，可手动继续本批。"
                )
            }
            if session.ghostwriteProgress?.shouldOfferRevisionSheet == true {
                return IOSAppLocalization.string(
                    "建议先「按审稿意见润修」（可改要求）；也可整章重写或先改本章计划。不会用旧稿再验。",
                    defaultValue: "建议先「按审稿意见润修」（可改要求）；也可整章重写或先改本章计划。不会用旧稿再验。"
                )
            }
            if session.ghostwriteProgress?.pauseReason == .continuityAuditIncomplete {
                return IOSAppLocalization.string(
                    "检查链路未扫稳（不是剧情硬伤）。继续会对同一篇候选稿再检，不会重写。",
                    defaultValue: "检查链路未扫稳（不是剧情硬伤）。继续会对同一篇候选稿再检，不会重写。"
                )
            }
            if session.ghostwriteProgress?.mustRewriteCandidateOnResume == true {
                return IOSAppLocalization.string(
                    "继续将重写本章，不会用同一篇旧稿再审核。",
                    defaultValue: "继续将重写本章，不会用同一篇旧稿再审核。"
                )
            }
            return IOSAppLocalization.string(
                "继续本批：先处理同步或拟定计划，再往下写。",
                defaultValue: "继续本批：先处理同步或拟定计划，再往下写。"
            )
        }
        // 完批后明确告诉用户：上一批已完成，点按钮开始下一批。
        if session.ghostwriteProgress?.pauseReason == .batchCompleted {
            return IOSAppLocalization.string(
                "上一批已全部完成并收录。点「代笔下一批」继续连写，或修改章数后再开始。",
                defaultValue: "上一批已全部完成并收录。点「代笔下一批」继续连写，或修改章数后再开始。"
            )
        }
        if session.ghostwriteProgress?.pauseReason == .chapterCompleted {
            return IOSAppLocalization.string(
                "本章已完成。点「代笔下一章」继续，或修改章数后再开始。",
                defaultValue: "本章已完成。点「代笔下一章」继续，或修改章数后再开始。"
            )
        }
        return IOSAppLocalization.formatted(
            "最多连续 %lld 章。首章可用「根据前文生成草稿」再确认；之后自动拟计划并连写。写不过会自动改写几次，仍不过会停，不会假装写完。",
            defaultValue: "最多连续 %lld 章。首章可用「根据前文生成草稿」再确认；之后自动拟计划并连写。写不过会自动改写几次，仍不过会停，不会假装写完。",
            arguments: [NovelGhostwriteBatch.maxChapterCount]
        )
    }

    private var toolbarGhostwriteActionTitle: String {
        let title = NovelGhostwriteSheetChrome.trailingActionTitle(
            isGhostwriting: session.isGhostwriting,
            pauseReason: session.ghostwriteProgress?.pauseReason,
            shouldContinueSameBatch: shouldShowContinueGhostwrite
        )
        return IOSAppLocalization.string(title, defaultValue: title)
    }

    private var toolbarGhostwriteActionDisabled: Bool {
        if session.isGhostwriting { return false }
        return !session.canStartGhostwriteChapter
    }

    private func performToolbarGhostwriteAction() {
        if session.isGhostwriting {
            session.pauseGhostwrite()
            return
        }
        if session.ghostwriteProgress?.pauseReason == .blockingContinuity {
            isPresentingGhostwriteRevision = true
            return
        }
        if shouldShowContinueGhostwrite
            || session.ghostwriteProgress?.pauseReason == .planProposedForNewBatch {
            _ = session.continueGhostwriteChapter()
            return
        }
        let n = NovelGhostwriteBatch.clamp(session.ghostwriteTargetChapterCount)
        _ = session.startGhostwriteChapter(targetChapterCount: n)
    }

    /// 质量失败时标明「将重写」，避免用户以为再点继续是复验旧稿。
    private var continueGhostwriteButtonTitle: String {
        guard let progress = session.ghostwriteProgress else {
            return IOSAppLocalization.string("继续代笔", defaultValue: "继续代笔")
        }
        if progress.pauseReason == .continuityAuditIncomplete {
            return IOSAppLocalization.string("再检查同一篇", defaultValue: "再检查同一篇")
        }
        if progress.pauseReason == .syncFailed {
            return IOSAppLocalization.string("继续同步", defaultValue: "继续同步")
        }
        if progress.pauseReason == .healBudgetExhausted {
            return IOSAppLocalization.string("继续重写本章", defaultValue: "继续重写本章")
        }
        if progress.mustRewriteCandidateOnResume {
            return IOSAppLocalization.string("继续代笔 · 将重写", defaultValue: "继续代笔 · 将重写")
        }
        return IOSAppLocalization.string("继续代笔", defaultValue: "继续代笔")
    }

    private var ghostwriteDisplayedTargetCount: Int {
        if shouldShowContinueGhostwrite,
           let fixed = session.ghostwriteProgress?.targetChapterCount {
            return NovelGhostwriteBatch.clamp(fixed)
        }
        return NovelGhostwriteBatch.clamp(session.ghostwriteTargetChapterCount)
    }

    private var currentChapterPlan: NovelChapterPlanRecord? {
        workspace.selectedBranchID.flatMap { workspace.projectSnapshot?.chapterPlan(for: $0) }
    }

    private var currentUpcomingArc: NovelUpcomingArcRecord? {
        workspace.selectedBranchID.flatMap { workspace.projectSnapshot?.upcomingArc(for: $0) }
    }

    private var planStatusLabel: String {
        guard let plan = currentChapterPlan else {
            return IOSAppLocalization.string("未创建", defaultValue: "未创建")
        }
        switch plan.status {
        case .draft: return IOSAppLocalization.string("草稿", defaultValue: "草稿")
        case .confirmed: return IOSAppLocalization.string("已确认", defaultValue: "已确认")
        }
    }

    private var upcomingArcStatusLabel: String {
        guard let arc = currentUpcomingArc, !arc.beats.isEmpty else {
            return IOSAppLocalization.string("未设置", defaultValue: "未设置")
        }
        return IOSAppLocalization.formatted(
            "%lld 条",
            defaultValue: "%lld 条",
            arguments: [arc.beats.count]
        )
    }

    private var reviewModelLabel: String {
        _ = sharedSettings.revision
        let configured = workspace.projectSnapshot?.project.configuredModelPolicy(for: .review)
            ?? .global
        let effective: NovelProjectModelPolicy = {
            if case .global = configured {
                return NovelCreationModelPreferences.shared.policy(for: .review)
            }
            return configured
        }()
        let name = NovelPresentation.modelDisplayName(
            for: effective,
            sharedSettings: sharedSettings
        )
        if case .global = configured {
            return IOSAppLocalization.formatted(
                "小说默认 · %@",
                defaultValue: "小说默认 · %@",
                arguments: [name]
            )
        }
        return name
    }

    private var upcomingArcFieldSyncToken: String {
        guard let arc = currentUpcomingArc else { return "none" }
        return "\(arc.branchID.rawValue.uuidString)|\(arc.beats.joined(separator: "|"))|\(arc.updatedAt.timeIntervalSince1970)"
    }

    private var ghostwriteSwitchBlockers: [NovelGhostwriteReadinessIssue] {
        ghostwriteReadinessCache.issues(for: workspace)
    }

    private var canEditChapterPlan: Bool {
        (workspace.canMutate || savingChapterPlanStatus != nil) &&
            !session.isGhostwriting && !isProposingPlanDraft
    }

    private var canEditUpcomingArc: Bool {
        (workspace.canMutate || isSavingUpcomingArc) &&
            !session.isGhostwriting && !isProposingPlanDraft
    }

    /// 尚无确认计划时露出「根据前文生成」；已确认则隐藏（避免盖掉手改合同）。
    private var canShowProposePlanDraft: Bool {
        currentChapterPlan?.status != .confirmed
    }

    private var canProposePlanDraft: Bool {
        canEditChapterPlan && !isProposingPlanDraft && savingChapterPlanStatus == nil
    }

    private var proposePlanDraftButtonTitle: String {
        if isProposingPlanDraft {
            return IOSAppLocalization.string("正在根据前文生成…", defaultValue: "正在根据前文生成…")
        }
        if currentChapterPlan?.status == .draft {
            return IOSAppLocalization.string("重新根据前文生成", defaultValue: "重新根据前文生成")
        }
        return IOSAppLocalization.string("根据前文生成草稿", defaultValue: "根据前文生成草稿")
    }

    private var chapterPlanSectionFooter: String {
        if collaborationMode == .ghostwrite {
            if canShowProposePlanDraft {
                return IOSAppLocalization.string(
                    "可先「根据前文生成草稿」，核对后点确认计划，再开始代笔。代笔进行中不能改。",
                    defaultValue: "可先「根据前文生成草稿」，核对后点确认计划，再开始代笔。代笔进行中不能改。"
                )
            }
            return IOSAppLocalization.string(
                "代笔写整章前要先确认计划；代笔进行中不能改。",
                defaultValue: "代笔写整章前要先确认计划；代笔进行中不能改。"
            )
        }
        if canShowProposePlanDraft {
            return IOSAppLocalization.string(
                "可先「根据前文生成草稿」，也可手写；确认后写整章时会带上。",
                defaultValue: "可先「根据前文生成草稿」，也可手写；确认后写整章时会带上。"
            )
        }
        return IOSAppLocalization.string(
            "可以先写好本章计划；确认后写整章时会带上。",
            defaultValue: "可以先写好本章计划；确认后写整章时会带上。"
        )
    }

    private func reloadPlanFieldsFromWorkspace() {
        writingContextFields.reloadPlan(currentChapterPlan)
    }

    private func reloadUpcomingArcFromWorkspace() {
        writingContextFields.reloadArc(currentUpcomingArc)
    }

    private func selectCollaborationMode(_ mode: NovelCollaborationMode) {
        guard !isSavingCollaborationMode else {
            selectedMode = persistedCollaborationMode
            return
        }
        guard mode != persistedCollaborationMode else { return }
        modeSwitchMessage = nil
        if mode == .cocreation, session.isGhostwriting || session.isRunning {
            selectedMode = persistedCollaborationMode
            modeSwitchMessage = "当前生成仍在进行，请先停止再切回共创。"
            return
        }
        if mode == .ghostwrite, !ghostwriteSwitchBlockers.isEmpty {
            selectedMode = persistedCollaborationMode
            modeSwitchMessage = "无法切入代笔，请先补齐下方缺项。"
            return
        }
        isSavingCollaborationMode = true
        Task { @MainActor in
            let saved = await workspace.setCollaborationMode(mode)
            isSavingCollaborationMode = false
            if saved {
                selectedMode = mode
                session.reconcileComposerIntent()
            } else {
                selectedMode = persistedCollaborationMode
                modeSwitchMessage = workspace.errorMessage ?? "模式切换失败，请重试。"
            }
        }
    }

    private func saveChapterPlan(status: NovelChapterPlanStatus) {
        guard savingChapterPlanStatus == nil else { return }
        planMessage = nil
        planMessageIsError = false
        // Belt-and-suspenders: bank already flushed on the button path.
        writingContextFields.fieldBank.commitAll()
        let submittedRevision = writingContextFields.planEditRevision
        let outlinePlacement = writingContextFields.planPlacement
        let goalAndConflict = writingContextFields.planGoal
        let mustHappen = planLines(from: writingContextFields.planMustHappen)
        let mustNotHappen = planLines(from: writingContextFields.planMustNotHappen)
        let endingHook = writingContextFields.planEndingHook
        let visibleFacts = planLines(from: writingContextFields.planVisibleFacts)
        let draft = NovelChapterPlanDraft(
            outlinePlacement: outlinePlacement, goalAndConflict: goalAndConflict,
            mustHappen: mustHappen, mustNotHappen: mustNotHappen,
            endingHook: endingHook, visibleFacts: visibleFacts
        )
        let draftOwner = planDraftOwner
        savingChapterPlanStatus = status
        savingChapterPlanRevision = submittedRevision
        chapterPlanSaveTask = Task { @MainActor in
            let saved = await workspace.upsertChapterPlan(
                status: status,
                outlinePlacement: outlinePlacement,
                goalAndConflict: goalAndConflict,
                mustHappen: mustHappen,
                mustNotHappen: mustNotHappen,
                endingHook: endingHook,
                visibleFacts: visibleFacts
            )
            if saved {
                if let draftOwner {
                    workspace.clearChapterPlanDraft(ifMatching: draft, projectID: draftOwner.projectID, branchID: draftOwner.branchID)
                }
                writingContextFields.markPlanClean(ifUnchangedSince: submittedRevision)
                planMessage = status == .confirmed ? "已确认，可以按这个写。" : "草稿已保存。"
                planMessageIsError = false
            } else {
                planMessage = workspace.errorMessage ?? "本章计划保存失败。"
                planMessageIsError = true
            }
            savingChapterPlanStatus = nil
            savingChapterPlanRevision = nil
            chapterPlanSaveTask = nil
            return saved
        }
    }

    /// 用总纲/剧情状态/上一批摘要生成草稿本章计划，不自动确认。
    private func proposeChapterPlanDraft() async {
        guard canProposePlanDraft,
              let projectID = workspace.selectedProjectID,
              let branchID = workspace.selectedBranchID else {
            planMessage = "当前无法生成计划。"
            planMessageIsError = true
            return
        }
        planMessage = nil
        planMessageIsError = false
        writingContextFields.fieldBank.commitAll()
        isProposingPlanDraft = true
        defer { isProposingPlanDraft = false }

        let branch = workspace.projectSnapshot?.branches.first { $0.id == branchID }
        let ordinal = max(1, (branch?.workingChapterSelections.count ?? 0) + 1)
        let previousSummary = session.ghostwriteProgress?.lastCompletedPlanSummary
        let draftOwner = planDraftOwner
        let retainedDraft = draftOwner.flatMap {
            workspace.chapterPlanDraft(projectID: $0.projectID, branchID: $0.branchID)
        }
        do {
            let plan = try await workspace.proposeNextChapterPlanDraft(
                projectID: projectID,
                branchID: branchID,
                nextChapterOrdinal: ordinal,
                previousPlanSummary: previousSummary
            )
            if let draftOwner, let retainedDraft {
                workspace.clearChapterPlanDraft(ifMatching: retainedDraft, projectID: draftOwner.projectID, branchID: draftOwner.branchID)
            }
            // 优先用返回值回填，避免 refresh 滞后时字段仍空。
            applyChapterPlanToFields(plan)
            planMessage = "已根据前文生成草稿，请核对后点「确认计划」。"
            planMessageIsError = false
        } catch {
            planMessage = NovelPresentation.operationErrorMessage(error)
            planMessageIsError = true
        }
    }

    private func applyChapterPlanToFields(_ plan: NovelChapterPlanRecord) {
        writingContextFields.reloadPlan(plan)
    }

    private func clearChapterPlan() async {
        planMessage = nil
        planMessageIsError = false
        writingContextFields.fieldBank.commitAll()
        let draftOwner = planDraftOwner
        let cleared = await workspace.clearChapterPlan()
        if cleared {
            if let draftOwner {
                workspace.clearChapterPlanDraft(projectID: draftOwner.projectID, branchID: draftOwner.branchID)
            }
            writingContextFields.reloadPlan(nil)
            planMessage = "计划已清除。"
            planMessageIsError = false
        } else {
            planMessage = workspace.errorMessage ?? "清除本章计划失败。"
            planMessageIsError = true
        }
    }

    private func saveUpcomingArc() {
        guard !isSavingUpcomingArc else { return }
        arcMessage = nil
        arcMessageIsError = false
        writingContextFields.fieldBank.commitAll()
        let beats = planLines(from: writingContextFields.upcomingArcBeats)
        guard !beats.isEmpty else {
            arcMessage = "请至少写一条。"
            arcMessageIsError = true
            return
        }
        let submittedRevision = writingContextFields.arcEditRevision
        isSavingUpcomingArc = true
        Task { @MainActor in
            let saved = await workspace.upsertUpcomingArc(beats: beats)
            if saved {
                writingContextFields.markArcClean(ifUnchangedSince: submittedRevision)
                arcMessage = "已保存。"
                arcMessageIsError = false
            } else {
                arcMessage = workspace.errorMessage ?? "保存失败。"
                arcMessageIsError = true
            }
            isSavingUpcomingArc = false
        }
    }

    private func clearUpcomingArc() async {
        arcMessage = nil
        arcMessageIsError = false
        writingContextFields.fieldBank.commitAll()
        let cleared = await workspace.clearUpcomingArc()
        if cleared {
            writingContextFields.reloadArc(nil)
            arcMessage = "备注已清除。"
            arcMessageIsError = false
        } else {
            arcMessage = workspace.errorMessage ?? "清除失败。"
            arcMessageIsError = true
        }
    }

    private func planLines(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func applyDraftBeforeTransition(_ transition: @escaping () -> Void) {
        NovelTextInputCommitter.perform(fieldBank: writingContextFields.fieldBank) {
            onApply(overrides, budgetTokens)
            transition()
        }
    }

    private var overrides: NovelInjectionOverrides {
        NovelWritingInjectionSelection.overrides(for: materialChoices)
    }

    private var matchingPreview: NovelInjectionPreviewSnapshot? {
        NovelWritingInjectionSelection.matchingPreview(
            workspace: workspace,
            previewSignature: previewSignature,
            currentSignature: currentPreviewSignature
        )
    }

    private var canPreview: Bool {
        workspace.canMutate && !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasWritingRequirements: Bool {
        workspace.activeMaterials.contains {
            if case .writingRequirements = $0.kind { return true }
            return false
        }
    }

    private var hasPolishPreference: Bool {
        workspace.projectSnapshot?.project.polishPreference.isEmpty == false
    }

    private func preview() {
        guard let projectID = workspace.selectedProjectID,
              let branchID = workspace.selectedBranchID else { return }
        let request = NovelWritingInjectionSelection.previewRequest(
            projectID: projectID,
            branchID: branchID,
            mode: mode,
            granularity: granularity,
            userText: userText,
            overrides: overrides,
            budgetTokens: budgetTokens
        )
        previewSignature = nil
        let requestSignature = currentPreviewSignature
        Task { @MainActor in
            guard let preview = await workspace.previewInjection(request),
                  currentPreviewSignature == requestSignature,
                  preview.projectID == projectID,
                  preview.branchID == branchID,
                  preview.requestedInputBudgetTokens == budgetTokens else { return }
            previewSignature = requestSignature
        }
    }

    private var currentPreviewSignature: String {
        NovelWritingInjectionSelection.signature(
            mode: mode,
            granularity: granularity,
            userText: userText,
            budgetTokens: budgetTokens,
            workspace: workspace,
            overrides: overrides
        )
    }


}
