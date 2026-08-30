import SwiftUI

/// 剧情矛盾检查在「设定 → 剧情」页里的那一段。发起前先给预估(扫几章、几次模型
/// 调用),扫完把每条问题的双方原文并排列出来,点一下跳到对应章节。
struct NovelContinuityAuditSection: View {
    let viewModel: NovelCreationViewModel
    let onOpenChapter: (NovelChapterSelection) -> Void
    @State private var pendingRepair: RepairTarget?

    var body: some View {
        Section("剧情矛盾检查") {
            // 失败必须说出来。这条链路上没有任何全局错误横幅,不显示就等于
            // 「点了没反应」——那正是上一轮功能被判定为「没做」的原因。
            if let failure = viewModel.continuityAuditFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }

            if viewModel.isContinuityOperationRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(viewModel.continuityOperationTitle)
                        .foregroundStyle(AmberTheme.muted)
                }
                .padding(.vertical, 3)
                Button("停止", role: .destructive) {
                    viewModel.cancelContinuityAudit()
                }
            } else if let report = viewModel.continuityAudit {
                reportHeader(report)
                if let repair = viewModel.continuityRepair {
                    repairSummary(repair)
                }
                if viewModel.visibleContinuityIssues.isEmpty {
                    Text(
                        viewModel.continuityRepair?.repairedIssueIDs.isEmpty == false
                            ? "已按检查结果改写冲突段落。建议再检查一次确认。"
                            : "没有发现前后打架的地方。"
                    )
                        .foregroundStyle(AmberTheme.muted)
                } else {
                    ForEach(viewModel.visibleContinuityIssues) { issue in
                        NovelContinuityIssueRow(
                            issue: issue,
                            canRepair: canRepair(report) && canRepairIssue(issue),
                            showsRepair: canRepairIssue(issue),
                            selection: selection(for:),
                            onOpenChapter: onOpenChapter,
                            onRepair: {
                                pendingRepair = .issue(issue.id)
                            }
                        )
                    }
                }
                if report.droppedIssueCount > 0 {
                    Text("另有 \(report.droppedIssueCount) 条被丢弃：模型给的章节号和原文都对不上，无法核实。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                if report.failedChunkCount > 0 {
                    Text("有 \(report.failedChunkCount) 段正文没扫成功，这份结果不完整，可以重新检查。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                }
                if viewModel.visibleContinuityIssues.contains(where: canRepairIssue) {
                    Button {
                        pendingRepair = .all
                    } label: {
                        Label("一键修复", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(!canRepair(report))
                }
                Button("重新检查") {
                    viewModel.clearContinuityAudit()
                    viewModel.startContinuityAuditPlanning()
                }
                .disabled(!viewModel.canMutate)
            } else if let plan = viewModel.continuityAuditPlan {
                // 预估直接摊在页面上,不弹窗:用户先看清这一趟要读多少、要发几次请求,
                // 再决定要不要开始。
                Text(verbatim: IOSAppLocalization.formatted(
                    "要通读 %lld 章、约 %lld 字，会分 %lld 次交给模型。检查期间不能生成正文。",
                    defaultValue: "要通读 %lld 章、约 %lld 字，会分 %lld 次交给模型。检查期间不能生成正文。",
                    arguments: [
                        Int64(plan.chapterCount),
                        Int64(plan.totalCharacterCount),
                        Int64(plan.chunkCount),
                    ]
                ))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                Button("确认开始") {
                    viewModel.startContinuityAudit()
                }
                .disabled(!viewModel.canMutate)
                Button("取消") { viewModel.clearContinuityAuditPlan() }
            } else {
                Text("通读当前分支的全部正文，找出重复写过的情节、前后互相矛盾的说法，以及明明见过却写成初次见面这类问题。只检查，不改动一个字。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                Button {
                    viewModel.startContinuityAuditPlanning()
                } label: {
                    Label("开始检查", systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!viewModel.canMutate)
            }
        }
        .confirmationDialog(
            pendingRepair == .all ? "按检查结果改写冲突？" : "修复这一处冲突？",
            isPresented: Binding(
                get: { pendingRepair != nil },
                set: { if !$0 { pendingRepair = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRepair
        ) { target in
            Button("开始修复") {
                switch target {
                case .all:
                    viewModel.startContinuityRepair()
                case .issue(let issueID):
                    viewModel.startContinuityRepair(issueIDs: [issueID])
                }
                pendingRepair = nil
            }
            Button("取消", role: .cancel) {
                pendingRepair = nil
            }
        } message: { _ in
            Text("后文向先文对齐，只改冲突段落。写入的版本可在章节版本历史撤销。")
        }
    }

    private enum RepairTarget: Equatable, Hashable {
        case all
        case issue(String)
    }

    @ViewBuilder
    private func repairSummary(_ repair: NovelContinuityRepairReport) -> some View {
        let repaired = repair.repairedIssueIDs.count
        let skipped = repair.skippedIssueIDs.count
        if repaired > 0 {
            Text("已改写 \(repair.repairedChapterCount) 章、\(repaired) 处冲突。")
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
        }
        if skipped > 0 || repair.failedChapterCount > 0 {
            if let audit = viewModel.continuityAudit, isStale(audit) {
                Text("另有 \(skipped) 处未能自动改写。正文已改过，请重新检查后再试。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            } else {
                Text("另有 \(skipped) 处未能自动改写，可点单条「修复」或重新检查。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            }
        }
    }

    @ViewBuilder
    private func reportHeader(_ report: NovelContinuityAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("扫描了 \(report.scannedChapterCount) 章，发现 \(report.issues.count) 处问题")
                .foregroundStyle(AmberTheme.foreground)
            if isStale(report) {
                Text("正文在这次扫描之后又改过了，结果可能已经过期。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            }
        }
        .padding(.vertical, 3)
    }

    private func isStale(_ report: NovelContinuityAuditReport) -> Bool {
        guard let branch = viewModel.branchSnapshot?.branch else { return true }
        let discarded = Set(
            (viewModel.projectSnapshot?.chapters ?? [])
                .filter { $0.discardedAt != nil }
                .map(\.id)
        )
        return report.isStale(against: branch, discardedChapterIDs: discarded)
    }

    private func canRepair(_ report: NovelContinuityAuditReport) -> Bool {
        viewModel.canMutate &&
            viewModel.visibleContinuityIssues.contains(where: canRepairIssue) &&
            !isStale(report)
    }

    private func canRepairIssue(_ issue: NovelContinuityIssue) -> Bool {
        NovelContinuityRepairPlanner.targetReference(in: issue) != nil
    }

    /// 报告里只有 chapterID —— 阅读器要的是「章 + 版本」这一对，版本以当前分支
    /// 工作区选中的那一版为准。查不到就说明这一章已经不在分支上了。
    private func selection(for chapterID: NovelChapterID) -> NovelChapterSelection? {
        viewModel.branchSnapshot?.branch.workingChapterSelections
            .first { $0.chapterID == chapterID }
    }
}

private struct NovelContinuityIssueRow: View {
    let issue: NovelContinuityIssue
    let canRepair: Bool
    let showsRepair: Bool
    let selection: (NovelChapterID) -> NovelChapterSelection?
    let onOpenChapter: (NovelChapterSelection) -> Void
    let onRepair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(issue.category.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(issue.severity.displayName)
                    .font(.caption)
                    .foregroundStyle(issue.severity.tint)
                Spacer(minLength: 8)
            }
            Text(issue.summary)
                .foregroundStyle(AmberTheme.foreground)
            ForEach(Array(issue.references.enumerated()), id: \.offset) { _, reference in
                if let target = selection(reference.chapterID) {
                    Button {
                        onOpenChapter(target)
                    } label: {
                        referenceBody(reference, isReachable: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    // 跳不过去就别装成可点的:这一章已经不在当前分支上了。
                    VStack(alignment: .leading, spacing: 2) {
                        referenceBody(reference, isReachable: false)
                        Text("这一章已不在当前分支")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
            }
            if showsRepair {
                HStack {
                    Spacer()
                    Button("修复", action: onRepair)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(!canRepair)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func referenceBody(
        _ reference: NovelContinuityReference,
        isReachable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: IOSAppLocalization.formatted(
                "第 %lld 章「%@」",
                defaultValue: "第 %lld 章「%@」",
                arguments: [Int64(reference.chapterOrdinal), reference.chapterTitle]
            ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isReachable ? AmberTheme.accent : AmberTheme.muted)
            Text(reference.evidence)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NovelContinuityIssueCategoryV1 {
    var displayName: String {
        switch self {
        case .duplicatedPlot: IOSAppLocalization.string("情节重复", defaultValue: "情节重复")
        case .contradiction: IOSAppLocalization.string("前后矛盾", defaultValue: "前后矛盾")
        case .identityDrift: IOSAppLocalization.string("人物关系对不上", defaultValue: "人物关系对不上")
        case .chronology: IOSAppLocalization.string("时间线错乱", defaultValue: "时间线错乱")
        case .statusConflict: IOSAppLocalization.string("状态冲突", defaultValue: "状态冲突")
        case .other: IOSAppLocalization.string("其他", defaultValue: "其他")
        }
    }
}

extension NovelContinuityIssueSeverityV1 {
    var displayName: String {
        switch self {
        case .blocking: IOSAppLocalization.string("严重", defaultValue: "严重")
        case .major: IOSAppLocalization.string("明显", defaultValue: "明显")
        case .minor: IOSAppLocalization.string("轻微", defaultValue: "轻微")
        }
    }

    var tint: Color {
        switch self {
        case .blocking: AmberTheme.accentRed
        case .major: AmberTheme.foreground2
        case .minor: AmberTheme.muted
        }
    }
}
