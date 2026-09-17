import SwiftUI
@preconcurrency import Shared

struct MemoryOverviewView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore

    @State private var persistence = IOSMemoryPersistence.shared
    @State private var selectedTab: MemorySettingsTab = .soul
    @Namespace private var tabSelection
    @State private var showSoulEditor = false
    @State private var soulDraft = ""
    @State private var showSoulRollbackConfirmation = false
    @State private var soulPreviousStore = IOSSoulPreviousStore()
    @State private var auditStore = IOSMemoryWriteAuditStore.shared
    @State private var extraction = IOSMemoryExtractionCoordinator.shared
    @State private var consolidation = IOSMemoryConsolidationCoordinator.shared
    @State private var operationError: String?
    @State private var showClearAuditConfirmation = false
    /// P2-a: 受外部内容影响（POLLUTED）的会话数；空态时整节不显示。
    @State private var pollutedConversations: [ConversationSummary] = []
    /// 派生的记忆文档列表（index.md + topics/）；随 persistence.revision 刷新。
    /// 初始值同步读取，避免首帧先渲染"光杆管理行"再闪现出文档。
    @State private var documents = IOSMemoryPersistence.shared.memoryDocuments()

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    chrome
                    switch selectedTab {
                    case .soul:
                        soulSection
                    case .memory:
                        intro
                        loadStatusSection
                        runtimeSection
                        extractionSection
                        consolidationSection
                        pollutionSection
                        documentsSection
                        auditSection
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: refresh)
        .onChange(of: persistence.revision) { _, _ in
            documents = persistence.memoryDocuments()
        }
        .alert("无法保存", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好") { operationError = nil }
        } message: {
            Text(operationError ?? "未知错误")
        }
        .confirmationDialog(
            "清除写入审批记录？",
            isPresented: $showClearAuditConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除记录", role: .destructive) {
                auditStore.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清除审批历史，不会删除已保存的记忆。")
        }
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                    dismiss()
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("灵魂与记忆")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(selectedTab == .soul ? "Amber 的核心指令" : "\(persistence.records.filter { !$0.archived }.count) 条本地记忆")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                }

                Spacer()

                if selectedTab == .memory {
                    AmberGlassIconButton(
                        systemImage: "plus",
                        accessibilityLabel: "新增记忆",
                        size: 44,
                        symbolSize: 20,
                        tint: AmberTheme.accent,
                        prominent: true
                    ) {
                        router.navigate(to: .memoryEdit(recordId: nil, text: "", scope: "核心", pinned: false))
                    }
                    .disabled(persistence.loadState == .unreadable)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            tabPicker
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(MemorySettingsTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? AmberTheme.foreground : AmberTheme.foreground2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(AmberTheme.background.opacity(0.92))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(AmberTheme.borderSoft.opacity(0.9), lineWidth: 0.5)
                                    }
                                    .matchedGeometryEffect(id: "selection", in: tabSelection)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private var soulSection: some View {
        VStack(spacing: 0) {
            Text("下次模型请求才会使用这里的正文，不会写入聊天历史。")
                .font(.callout)
                .foregroundStyle(AmberTheme.foreground2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            AmberSectionLabel(text: "灵魂")
            AmberFormGroup {
                let soul = sharedSettings.agentRuntime.agentSoulMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        Text(soul.isEmpty ? "还没有核心指令。" : soul)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(soul.isEmpty ? AmberTheme.muted : AmberTheme.foreground)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: 220)
                    Button("编辑核心指令") {
                        soulDraft = sharedSettings.agentRuntime.agentSoulMarkdown
                        showSoulEditor = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    if canRollbackSoul {
                        Button("回退上一个核心指令") {
                            showSoulRollbackConfirmation = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentAmber)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .sheet(isPresented: $showSoulEditor) {
            NavigationStack {
                TextEditor(text: $soulDraft)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground)
                    .scrollContentBackground(.hidden)
                    .background(AmberTheme.background)
                    .padding(.horizontal, 12)
                    .navigationTitle("编辑核心指令")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showSoulEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                sharedSettings.setAgentSoulMarkdown(soulDraft)
                                showSoulEditor = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .confirmationDialog(
            "回退上一个核心指令？",
            isPresented: $showSoulRollbackConfirmation,
            titleVisibility: .visible
        ) {
            Button("回退", role: .destructive) {
                rollbackSoul()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只有当前版本仍是上次应用版本时才会恢复。之后的手工修改不会被覆盖。")
        }
    }

    private var canRollbackSoul: Bool {
        _ = sharedSettings.revision
        return IOSSoulService(
            workspaceStore: .shared,
            sharedSettings: sharedSettings,
            previousStore: soulPreviousStore
        ).canRollback
    }

    private func rollbackSoul() {
        do {
            try IOSSoulService(
                workspaceStore: .shared,
                sharedSettings: sharedSettings,
                previousStore: soulPreviousStore
            ).rollbackPrevious()
        } catch {
            operationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private var loadStatusSection: some View {
        if persistence.loadState == .unreadable {
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Label("现有记忆无法读取", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                    Text(persistence.lastErrorMessage ?? "已停止写入以保护原文件。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                    Button("重新读取") {
                        persistence.load()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .padding(.top, 14)
        }
    }

    private var intro: some View {
        Text("管理 Amber 会在聊天中参考的本地记忆。自动提炼只保存用户明确表达的偏好与项目事实，记录可以搜索、查看来源或删除。")
            .font(.callout)
            .foregroundStyle(AmberTheme.foreground2)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private var extractionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "自动积累")
            AmberFormGroup {
                MemoryPresetRow(
                    title: "聊天后提炼记忆",
                    subtitle: "默认使用压缩模型提炼用户发言，会产生额外模型调用。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.memoryWorker.enabled && sharedSettings.agentRuntime.memoryWorker.extractionEnabled },
                        set: { sharedSettings.setMemoryExtractionSettings(enabled: $0); extraction.retry() }
                    )
                )
                MemoryDivider()
                MemoryPresetRow(
                    title: "仅充电时提炼",
                    subtitle: "未充电时保留待处理记录，回到 App 后继续。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.memoryWorker.runOnlyOnCharging },
                        set: { sharedSettings.setMemoryExtractionSettings(runOnlyOnCharging: $0); extraction.retry() }
                    )
                )
                MemoryDivider()
                HStack(spacing: 12) {
                    Text(extraction.statusMessage)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if extraction.pendingCount > 0, !extraction.isRunning {
                        Button("重试") { extraction.retry() }
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var consolidationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "记忆整理")
            AmberFormGroup {
                MemoryPresetRow(
                    title: "自动整理记忆",
                    subtitle: "合并重复、归档过期记录，并把长期保留的短期记忆升级。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.memoryWorker.dreamMaintenanceEnabled },
                        set: {
                            sharedSettings.setMemoryDreamSettings(maintenanceEnabled: $0)
                            if $0 { consolidation.resume() }
                        }
                    )
                )
                MemoryDivider()
                MemoryPresetRow(
                    title: "主题聚合",
                    subtitle: "整理时让模型把相关记忆归入主题，并同步生成 Markdown 文档。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.memoryWorker.dreamModelEnabled },
                        set: {
                            sharedSettings.setMemoryDreamSettings(modelEnabled: $0)
                            if $0 { consolidation.resume() }
                        }
                    )
                )
                MemoryDivider()
                HStack(spacing: 12) {
                    Text(consolidation.statusMessage)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("立即整理") { consolidation.runNow() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(consolidationCanRun ? AmberTheme.accent : AmberTheme.muted2)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!consolidationCanRun)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    /// 立即整理可用条件：不在运行中、持久化已就绪（.missing 也是可写的空库）、
    /// 且至少一个整理开关打开——与 coordinator 的 isAnyDreamEnabled 门禁一致。
    private var consolidationCanRun: Bool {
        let worker = sharedSettings.agentRuntime.memoryWorker
        return !consolidation.isRunning
            && (persistence.loadState == .loaded || persistence.loadState == .missing)
            && (worker.dreamMaintenanceEnabled || worker.dreamModelEnabled)
    }

    private var runtimeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "记忆范围")
            AmberFormGroup {
                MemoryPresetRow(
                    title: "核心记忆",
                    subtitle: "长期偏好与重要事实。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.enableCoreMemory },
                        set: { sharedSettings.setMemoryRuntimeEnabled(core: $0) }
                    )
                )
                MemoryDivider()
                MemoryPresetRow(
                    title: "短期记忆",
                    subtitle: "近期项目上下文。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.enableShortTermMemory },
                        set: { sharedSettings.setMemoryRuntimeEnabled(shortTerm: $0) }
                    )
                )
                MemoryDivider()
                MemoryPresetRow(
                    title: "长期记忆",
                    subtitle: "跨会话保留的背景信息。",
                    isOn: Binding(
                        get: { sharedSettings.agentRuntime.enableLongTermMemory },
                        set: { sharedSettings.setMemoryRuntimeEnabled(longTerm: $0) }
                    )
                )
            }
        }
    }

    /// P2-a：受外部内容影响的会话（memoryMode == POLLUTED）压缩为一行汇总，
    /// 点按进入列表页逐个或全部恢复。空态不显示本小节。
    @ViewBuilder
    private var pollutionSection: some View {
        if !pollutedConversations.isEmpty {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "受外部内容影响的会话")
                AmberFormGroup {
                    Button {
                        router.navigate(to: .memoryPollutedConversations)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .accessibilityHidden(true)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AmberTheme.accentAmber)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(pollutedConversations.count) 个会话已暂停记忆提炼")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                                Text("曾调用联网搜索、网页抓取或 MCP 工具")
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AmberTheme.muted2)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看 \(pollutedConversations.count) 个已暂停记忆提炼的会话")
                }
            }
        }
    }

    /// 记忆文档：index.md 与各主题文档的文件式列表，点按进入只读详情。
    /// 单条记录的搜索/编辑/删除收进「管理全部记忆」二级页。
    private var documentsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "记忆文档")
            let liveCount = persistence.records.filter { !$0.archived }.count
            if documents.isEmpty && liveCount == 0 {
                AmberFormGroup {
                    MemoryEmptyState(isSearching: false)
                }
            } else {
                AmberFormGroup {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, doc in
                        Button {
                            router.navigate(to: .memoryDocument(relativePath: doc.relativePath, title: doc.title))
                        } label: {
                            MemoryDocumentRow(document: doc)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开 \(doc.title)")

                        if index < documents.count - 1 {
                            MemoryDivider(leading: 52)
                        }
                    }

                    if !documents.isEmpty {
                        MemoryDivider(leading: 52)
                    }

                    Button {
                        router.navigate(to: .memoryRecords)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tray.full")
                                .accessibilityHidden(true)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AmberTheme.muted)
                                .frame(width: 28, height: 28)
                            Text("管理全部记忆")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                            Spacer()
                            Text("\(liveCount) 条")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AmberTheme.muted2)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("管理全部记忆，共 \(liveCount) 条")
                }
            }
        }
    }

    private var auditSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "写入审批记录")
            AmberFormGroup {
                if auditStore.records.isEmpty {
                    Text("暂无模型写入审批记录。聊天里的新增、修改或删除请求会记录在这里；需要确认时会在聊天中提示。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(auditStore.records.prefix(5))) { record in
                        MemoryAuditRow(record: record)
                        MemoryDivider(leading: 52)
                    }

                    Button(role: .destructive) {
                        showClearAuditConfirmation = true
                    } label: {
                        Text("清除审批记录")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func refresh() {
        persistence.refresh()
        documents = persistence.memoryDocuments()
        Task { @MainActor in
            pollutedConversations = await conversationStore.pollutedConversationSummaries()
        }
    }
}

private enum MemorySettingsTab: String, CaseIterable, Identifiable {
    case soul
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soul: "灵魂"
        case .memory: "记忆"
        }
    }
}

/// 记忆文档行：文件名式标题 + 预览行 + 右侧大小/日期，对齐文件列表观感。
private struct MemoryDocumentRow: View {
    let document: IOSMemoryMarkdownDocument

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: document.relativePath == "index.md" ? "list.bullet.rectangle" : "doc.text")
                .accessibilityHidden(true)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                if !document.preview.isEmpty {
                    Text(document.preview)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(document.sizeBytes), countStyle: .file))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                Text(Self.dateFormatter.string(from: document.modifiedAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .fixedSize()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct MemoryAuditRow: View {
    let record: IOSMemoryWriteAuditRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .accessibilityHidden(true)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(IOSMemoryLibrary.actionDisplay(record.action)) · \(statusTitle)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String {
        // 不对用户展示内部 memoryId（如 #12）；范围/类型/预览足够定位。
        var parts: [String] = []
        if let scope = record.scope { parts.append(IOSMemoryLibrary.scopeDisplay(scope)) }
        if let kind = record.kind { parts.append(IOSMemoryLibrary.kindDisplay(kind)) }
        if let contentPreview = record.contentPreview { parts.append(contentPreview) }
        if parts.isEmpty, !record.reason.isEmpty { return record.reason }
        return parts.joined(separator: " · ")
    }

    private var statusTitle: String {
        switch record.status {
        case "approved": "已批准"
        case "user_saved": "用户保存"
        case "auto_saved": "自动保存"
        case "needs_user_action": "等待确认"
        case "denied", "denied_by_user": "已拒绝"
        case "user_deleted": "用户删除"
        default: "失败"
        }
    }

    private var statusIcon: String {
        switch record.status {
        case "approved", "user_saved", "auto_saved": "checkmark.circle.fill"
        case "needs_user_action": "hand.raised.fill"
        case "denied", "denied_by_user": "xmark.circle.fill"
        case "user_deleted": "trash.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case "approved", "user_saved", "auto_saved": AmberTheme.accentGreen
        case "needs_user_action": AmberTheme.accentAmber
        case "denied", "denied_by_user", "user_deleted": AmberTheme.accentRed
        default: AmberTheme.accentAmber
        }
    }
}

private struct MemoryPresetRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(AmberTheme.accent)
        }
        .frame(minHeight: 60)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .accessibilityLabel(title)
    }
}
