import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct ConversationsView: View {
    let sharedSettings: IOSSharedSettingsStore
    let chatViewModel: ChatViewModel
    let councilChatViewModel: CouncilChatViewModel
    let novelCreationViewModel: NovelCreationViewModel?

    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    /// Liquid Glass morph namespace（skill: glassEffectID + hierarchy change）。
    @Namespace private var homeSearchNamespace
    @State private var deepReadStore = IOSDeepReadStore.shared
    @State private var miniAppRepository = IOSMiniAppRepository.shared
    @State private var renamingConversationId: KotlinUuid?
    @State private var renameDraft: String = ""
    @State private var deletingConversationId: KotlinUuid?
    @State private var backgroundGenerationRevision = 0
    @State private var homeImageGenerationContext: ChatImageGenerationResumeContext?
    @State private var homeContinueError: String?
    @State private var isSearchExpanded = false
    @State private var conversationNavigationTask: Task<Void, Never>?
    @AppStorage(ChatImageGenerationResumeConsumption.viewedCompletionIDKey)
    private var viewedImageGenerationID = ""
    @FocusState private var searchFocused: Bool
    /// 展开后是否已真正拿到焦点；避免 expand 后 170ms 内 focused==false 误触发点外收起。
    @State private var searchHadFocus = false
    @AccessibilityFocusState private var deepReadShortcutFocused: Bool
    /// 展开搜索后的延迟聚焦任务：取消/离场必须可撤销，否则 170ms 内收起会残留 FocusState。
    @State private var searchFocusTask: Task<Void, Never>?
    /// 入场级联只播放一次：最晚一级 delay .22 + 时长 .48，0.9s 后全部按已入场处理。
    @State private var cascadeComplete = false
    /// iPhone Duo 外屏：搜索 / 设置 / 账户 / 新对话 搬到右侧竖条，顶栏与右下胶囊让位。
    @State private var sideRailActive = false
    @ScaledMetric(relativeTo: .subheadline) private var sectionLabelSize: CGFloat = 15

    /// 本地标题过滤后的会话摘要（summaries 已按 updateAt 倒序/置顶优先）。
    private var filteredSummaries: [ConversationSummary] {
        guard isSearchExpanded else { return conversationStore.summaries }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversationStore.summaries }
        return conversationStore.summaries.filter { summary in
            // 空标题会话用占位串参与匹配，避免搜索框里全是空白行。
            let title = summary.title.isEmpty ? "新对话" : summary.title
            return title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var homeImageGenerationScanSignature: Int {
        var hasher = Hasher()
        hasher.combine(conversationStore.backgroundContentRevision)
        hasher.combine(backgroundGenerationRevision)
        hasher.combine(chatViewModel.isLoading)
        for summary in conversationStore.summaries {
            hasher.combine(summary.id.toHexDashString())
            hasher.combine(summary.updateAt.toEpochMilliseconds())
        }
        return hasher.finalize()
    }

    var body: some View {
        // snapshot 为 @ObservationIgnored；读 revision 才能在改昵称后刷新头像首字。
        let _ = sharedSettings.revision
        let visibleSummaries = filteredSummaries
        GeometryReader { geometry in
        ZStack(alignment: .bottomTrailing) {
            // Canvas layer (color + optional texture). List structure unchanged.
            AmberCanvasBackground()

            // 用原生 List 承载整屏，会话行才能挂 .swipeActions(Apple Music 同款左右滑动)。
            // 顶部 header/搜索/快捷区作为清空背景的 List 行铺在上面，玻璃风格不受影响:
            // .scrollContentBackground(.hidden) + 每行 .listRowBackground(.clear) 让 List 自身
            // 不画任何底色，保留 AmberTheme.background。
            // 新建：右下拇指区真浮层胶囊（非顶栏、非圆 FAB、非 safeAreaInset 假底栏）。
            List {
                header.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).homeCascade(delay: 0.06, enabled: !cascadeComplete)
                // 搜索条单独成行：顶栏行高恒定，键盘收起/搜索折叠时 AMBER 与齿轮不随行高动画跳动。
                if isSearchExpanded {
                    expandedSearchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 15)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                controlCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .homeCascade(delay: 0.10, enabled: !cascadeComplete)
                    .simultaneousGesture(dismissSearchOutsideTap)
                Text("会话")
                    // Section chrome from theme pack; list row layout frozen; chat body font independent.
                    .font(AmberChromeFont.system(size: sectionLabelSize, weight: .semibold))
                    .foregroundStyle(AmberTheme.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 12)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).homeCascade(delay: 0.14, enabled: !cascadeComplete)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissSearchOutsideTap)

                if visibleSummaries.isEmpty {
                    HomeEmptyCard(title: isSearchExpanded && !searchQuery.isEmpty ? "没有匹配的会话" : "还没有会话")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .homeCascade(delay: 0.18, enabled: !cascadeComplete)
                        .simultaneousGesture(dismissSearchOutsideTap)
                } else {
                    conversationList(visibleSummaries)
                }

                // 滚到底时末行让过右下胶囊（仅 scroll 留白，无实色底栏）。
                Color.clear
                    .frame(height: homeNewChatCapsuleListClearance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissSearchOutsideTap)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 有点阵/方格时底部 soft 会把会话外框下沿「透」成雾面；改 hard 保住卡壳不透明。
            .scrollEdgeEffectStyle(
                AmberThemeRuntime.shared.canvasStyle.hasTexture ? .hard : .soft,
                for: .bottom
            )
            // 点到非搜索区导致失焦时收起（与 Esc/取消一致）。
            .onChange(of: searchFocused) { _, focused in
                if focused {
                    searchHadFocus = true
                } else if searchHadFocus, isSearchExpanded {
                    collapseSearch(clearQuery: false)
                }
            }

            // 右下拇指区：内容贴合胶囊浮在内容上（局部琥珀；非满幅条）。
            // trailing 28（非卡边 16）：相对会话外框内缩 12pt，避免胶囊右缘与卡边相切。
            // 视觉位置不变：外扩的热区从 inset 里扣回。
            if !sideRailActive {
            homeNewChatCapsule
                .padding(.trailing, homeNewChatCapsuleTrailingInset - homeNewChatCapsuleHitSlop)
                .padding(
                    .bottom,
                    (dynamicTypeSize.isAccessibilitySize
                        ? 12
                        : max(homeNewChatCapsuleBottomInset - geometry.safeAreaInsets.bottom, 12))
                        - homeNewChatCapsuleHitSlop
                )
                .homeCascade(delay: 0.22, enabled: !cascadeComplete)
            }
        }
        }
        .amberSideRail(isActive: $sideRailActive, top: homeSideRailTopItems, bottom: homeSideRailBottomItems)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobDidTerminate)) { _ in
            backgroundGenerationRevision &+= 1
        }
        .onAppear {
            Task { await novelCreationViewModel?.loadProjects(restoresSelection: false) }
            guard !cascadeComplete else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { cascadeComplete = true }
        }
        .task(id: homeImageGenerationScanSignature) {
            let context = await chatViewModel.latestImageGenerationResumeContext()
            guard !Task.isCancelled else { return }
            homeImageGenerationContext = context
        }
        .onChange(of: homeContinueModel) { oldValue, newValue in
            announceHomeContinueChange(from: oldValue, to: newValue)
        }
        .onChange(of: router.path) { _, path in
            if !path.isEmpty {
                conversationNavigationTask?.cancel()
            }
        }
        .onDisappear {
            searchFocusTask?.cancel()
            conversationNavigationTask?.cancel()
        }
        .alert("无法打开任务", isPresented: Binding(
            get: { homeContinueError != nil },
            set: { if !$0 { homeContinueError = nil } }
        )) {
            Button("好") { homeContinueError = nil }
        } message: {
            Text(homeContinueError ?? "图片所在会话暂不可用。")
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renamingConversationId != nil },
            set: { if !$0 { renamingConversationId = nil } }
        )) {
            TextField("会话标题", text: $renameDraft)
            Button("取消", role: .cancel) { renamingConversationId = nil }
            Button("保存") {
                if let id = renamingConversationId {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task { @MainActor in
                            await conversationStore.renameConversation(id: id, title: trimmed)
                        }
                    }
                }
                renamingConversationId = nil
            }
        }
        .alert("删除会话？", isPresented: Binding(
            get: { deletingConversationId != nil },
            set: { if !$0 { deletingConversationId = nil } }
        )) {
            Button("取消", role: .cancel) { deletingConversationId = nil }
            Button("删除", role: .destructive) {
                if let id = deletingConversationId {
                    Task { @MainActor in
                        await conversationStore.deleteConversation(id: id) { affectedIDs in
                            affectedIDs.forEach(chatViewModel.prepareForConversationDeletion)
                        }
                    }
                }
                deletingConversationId = nil
            }
        } message: {
            Text("此操作不可撤销，会话内的全部消息将被删除。关联子任务会停止，子会话记录保留在“对话存储”中。")
        }
    }

    private var accountInitial: String {
        let trimmed = sharedSettings.displaySetting.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "A" : trimmed).prefix(1)).uppercased()
    }

    /// Continue 显隐：0.30s 与搜索 expand 同曲线族；Reduce Motion 缩短。
    private var homeContinuePresenceMotion: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.15)
        }
        return .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.30)
    }

    /// 右下新建胶囊：略小于搜索 38 的「宽版」控制，仍 ≥ 拇指舒适区。
    private var homeNewChatCapsuleHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 48 : 42
    }

    /// 相对屏右 inset：大于会话卡 16，使胶囊相对外框内缩约 12pt。
    private var homeNewChatCapsuleTrailingInset: CGFloat { 28 }

    /// 相对屏底 inset（拇指区）。
    private var homeNewChatCapsuleBottomInset: CGFloat { 52 }

    /// 胶囊四周额外触控热区；玻璃外观不变，只扩大可点范围（贴角浮层易点偏）。
    private var homeNewChatCapsuleHitSlop: CGFloat { 10 }

    /// 列表底留白：胶囊高 + 余量（只滚空白，不铺实色栏）。
    private var homeNewChatCapsuleListClearance: CGFloat {
        homeNewChatCapsuleHeight + 36
    }

    /// 首页右下「新对话」浮层胶囊。
    /// skill 门禁：
    /// - taste：主强调动作；强调色混色玻璃 + on-accent 墨，压过 Continue 浅色 CTA
    /// - liquid glass：原生 prominent 按钮统一处理强调色、玻璃与按压形变
    /// - ui-patterns：拇指区 bottomTrailing 真浮层；非 top 难够、非 inset 假底栏
    private var homeNewChatCapsule: some View {
        let height = homeNewChatCapsuleHeight
        return Button(action: triggerHomeNewChat) {
            HStack(spacing: 6) {
                HomePhosphorIcon(.pencil, size: 14)
                    .foregroundStyle(AmberTheme.fabInk)
                Text("新对话")
                    .font(AmberChromeFont.system(size: 14, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(AmberTheme.fabInk)
            }
            .frame(maxHeight: .infinity)
        }
        .amberGlassButton(
            cornerRadius: height / 2, prominent: true, tint: AmberTheme.accent,
            borderShape: .capsule, sizing: .fitted
        )
        .controlSize(.regular)
        .frame(height: height)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("新建聊天")
        .accessibilityAddTraits(.isButton)
        // 胶囊外的一圈透明热区：点在玻璃边缘外侧也能新建；玻璃内仍由按钮自身处理按压形变。
        .padding(homeNewChatCapsuleHitSlop)
        .contentShape(Capsule())
        .onTapGesture(perform: triggerHomeNewChat)
    }

    private func triggerHomeNewChat() {
        AmberHaptics.trigger(.lightImpact)
        startNewConversation()
    }

    /// E 版 + Liquid Glass skill：
    /// - 玻璃只上控制层（搜索/齿轮 + 展开条 + 右下新建胶囊）
    /// - 展开条在独立 List 行（顶栏行高恒定），胶囊与条之间不再跨行 morph
    /// - 关闭相邻玻璃的融合距离；搜索与齿轮留出 18pt，按压不再膨胀黏连
    /// - 展开 0.32s 对齐原型 cubic-bezier(0.2,.8,.2,1)；Reduce Motion 缩短
    private var header: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    homeHeaderStack(useGlassEffectID: true)
                }
            } else {
                homeHeaderStack(useGlassEffectID: false)
            }
        }
        .animation(homeSearchMotion, value: isSearchExpanded)
    }

    private func homeHeaderStack(useGlassEffectID: Bool) -> some View {
        HStack(spacing: 10) {
            // Brand mark layer — HStack chrome layout frozen.
            AmberBrandMarkView()
                .layoutPriority(1)

            Spacer(minLength: 8)

            if !isSearchExpanded, !sideRailActive {
                homeSearchCapsuleButton
                    .modifier(HomeOptionalGlassEffectID(
                        id: useGlassEffectID ? "homeSearch" : nil,
                        namespace: useGlassEffectID ? homeSearchNamespace : nil
                    ))
                    .padding(.trailing, 8)
            }

            if !sideRailActive {
            homeSettingsGlassButton
                .modifier(HomeOptionalGlassEffectID(
                    id: useGlassEffectID ? "homeSettings" : nil,
                    namespace: useGlassEffectID ? homeSearchNamespace : nil
                ))

            Button {
                collapseSearchIfNeeded()
                router.navigate(to: .account)
            } label: {
                // 与搜索 38 / 齿轮 38 同高，顶栏控制簇尺度一致。
                HomeAccountAvatar(initial: accountInitial, size: 38)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.92, haptic: .lightImpact))
            .accessibilityLabel("我的账户")
            }
        }
        .frame(minHeight: 38)
        .padding(.horizontal, 16)
    }

    // MARK: - iPhone Duo 外屏右侧竖条

    private var homeSideRailTopItems: [AmberSideRailItem] {
        [
            AmberSideRailItem(id: "search", systemImage: "magnifyingglass", accessibilityLabel: "搜索") {
                AmberHaptics.trigger(.lightImpact)
                isSearchExpanded ? collapseSearch() : expandSearch()
            },
            AmberSideRailItem(id: "settings", systemImage: "gearshape", accessibilityLabel: "设置") {
                collapseSearchIfNeeded()
                router.navigate(to: .settings)
            },
            AmberSideRailItem(id: "account", systemImage: "person.crop.circle", accessibilityLabel: "我的账户") {
                collapseSearchIfNeeded()
                router.navigate(to: .account)
            },
        ]
    }

    /// 新对话放在竖条底部：外屏单手握持时拇指最容易够到。
    private var homeSideRailBottomItems: [AmberSideRailItem] {
        [AmberSideRailItem(id: "new-chat", systemImage: "square.and.pencil", accessibilityLabel: "新建聊天",
                           prominent: true, action: triggerHomeNewChat)]
    }

    private var homeSearchCapsuleButton: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            expandSearch()
        } label: {
            HStack(spacing: 6) {
                HomePhosphorIcon(.magnifyingGlass, size: 14)
                Text("搜索")
                    .font(AmberChromeFont.system(size: 13, weight: .semibold))
                    .tracking(0.26)
            }
            .foregroundStyle(AmberTheme.muted)
            .frame(maxHeight: .infinity)
        }
        .amberGlassButton(cornerRadius: 19, borderShape: .capsule, sizing: .fitted)
        .controlSize(.mini)
        .frame(minWidth: 78)
        .frame(height: 38)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("搜索")
        .accessibilityAddTraits(.isButton)
    }

    private var homeSettingsGlassButton: some View {
        HomeGlassCircleButton(
            icon: .gear,
            accessibilityLabel: "设置",
            size: 38,
            iconSize: 20,
            tint: AmberTheme.fab
        ) {
            collapseSearchIfNeeded()
            router.navigate(to: .settings)
        }
    }

    /// 展开后的全宽玻璃条：高 41、圆角 14（E 版实测）；独立 List 行，不改变顶栏行高。
    private var expandedSearchBar: some View {
        HStack(spacing: 14) {
            HomePhosphorIcon(.magnifyingGlass, size: 14)
                .foregroundStyle(AmberTheme.muted2)
            TextField("搜索会话", text: $searchQuery)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(AmberTheme.foreground)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    let submittedQuery = searchQuery
                    collapseSearch()
                    router.navigate(to: .search(initialQuery: submittedQuery))
                }
            Button("取消") { collapseSearch() }
                .font(AmberChromeFont.system(size: 13, weight: .semibold))
                .tracking(0.26)
                .foregroundStyle(AmberTheme.muted)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 41)
        .homeGlassControl(cornerRadius: 14, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.controlRadius(14), style: .continuous)
                .strokeBorder(AmberTheme.focusRing, lineWidth: 1.5)
                .opacity(searchFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onKeyPress(.escape) {
            collapseSearch()
            return .handled
        }
    }

    /// 原型 expand 0.32s；Reduce Motion 用短 ease，避免 glass morph 晃眼。
    private var homeSearchMotion: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.15)
        }
        // E 版 searchslot：cubic-bezier(0.2, 0.8, 0.2, 1) 0.32s
        return .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
    }

    /// 点控制卡 / 会话区 / 空白留白时收起（不抢子按钮点击，用 simultaneousGesture）。
    private var dismissSearchOutsideTap: some Gesture {
        TapGesture().onEnded { collapseSearchIfNeeded() }
    }

    private func expandSearch() {
        searchQuery = ""
        searchHadFocus = false
        // skill: hierarchy 变化时 withAnimation，才能触发 glass morph
        withAnimation(homeSearchMotion) {
            isSearchExpanded = true
        }
        searchFocusTask?.cancel()
        searchFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            // 170ms 内取消/收起/离场都会取消本任务，不会再写 FocusState。
            guard !Task.isCancelled, isSearchExpanded else { return }
            searchFocused = true
        }
    }

    private func collapseSearchIfNeeded() {
        searchQuery = ""
        guard isSearchExpanded else { return }
        collapseSearch()
    }

    private func collapseSearch(clearQuery: Bool = true) {
        searchFocusTask?.cancel()
        searchFocusTask = nil
        // 失焦可能先于 onSubmit；只有该路径保留草稿供提交读取。
        if clearQuery {
            searchQuery = ""
        }
        searchFocused = false
        searchHadFocus = false
        withAnimation(homeSearchMotion) {
            isSearchExpanded = false
        }
    }

    private func conversationList(_ visibleSummaries: [ConversationSummary]) -> some View {
        // `isLoading` is the observable foreground transition; background jobs
        // publish their terminal transition through `backgroundGenerationRevision`.
        // Reading both here keeps each row derived from the current owners rather
        // than preserving the off-screen NavigationStack snapshot.
        _ = chatViewModel.isLoading
        _ = backgroundGenerationRevision
        // 观察浓缩预览字典，生成完成后 meta 第二态能刷新到首页。
        _ = conversationStore.listPreviewsByConversationId
        _ = conversationStore.listIconsByConversationId
        let count = visibleSummaries.count
        return ForEach(Array(visibleSummaries.enumerated()), id: \.element.id) { index, summary in
            let isLast = index == count - 1
            ConversationSummaryRow(
                summary: summary,
                isCurrent: conversationStore.currentConversation?.id == summary.id,
                isGenerating: chatViewModel.isGenerationActive(conversationId: summary.id),
                listPreview: conversationStore.listPreview(for: summary.id),
                listIconKey: conversationStore.listIconKey(for: summary.id),
                slice: homeSlice(index: index, count: count),
                // 一体卡内：末行无底线；当前行与下一行若为当前则让 hairline 让位，避免与 accent 色带打架。
                hidesSeparator: isLast
                    || conversationStore.currentConversation?.id == summary.id
                    || (index + 1 < count
                        && conversationStore.currentConversation?.id == visibleSummaries[index + 1].id),
                onTap: {
                    openConversation(summary.id)
                },
                onRename: {
                    renameDraft = summary.title
                    renamingConversationId = summary.id
                },
                onTogglePin: {
                    Task { @MainActor in
                        await conversationStore.togglePin(id: summary.id)
                    }
                },
                onDelete: {
                    deletingConversationId = summary.id
                },
                onExport: { format in
                    exportConversation(id: summary.id, title: summary.title, format: format)
                }
            )
            .equatable()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .homeCascade(delay: 0.18, enabled: !cascadeComplete)
        }
    }

    private func homeSlice(index: Int, count: Int) -> HomeCardSlice {
        if count == 1 { return .single }
        if index == 0 { return .top }
        return index == count - 1 ? .bottom : .middle
    }

    private var homeContinueModel: HomeContinueCardModel? {
        let novelProjects = novelCreationViewModel?.projects.map(HomeNovelProjectRef.init) ?? []
        let councilTask = councilChatViewModel.homeResumeContext.map(HomeCouncilTaskRef.init)
        let deepReadTasks = deepReadStore.history.map(HomeDeepReadTaskRef.init)
        let imageGeneration = homeImageGenerationContext.flatMap { context -> HomeImageGenerationRef? in
            if context.state == .completed, context.id == viewedImageGenerationID {
                return nil
            }
            return HomeImageGenerationRef(context)
        }
        let miniApps = miniAppRepository.apps.compactMap { app -> HomeMiniAppRef? in
            guard let latestVersion = miniAppRepository.versions(appId: app.id).first else { return nil }
            return HomeMiniAppRef(
                id: app.id,
                title: app.title,
                latestVersionCreatedAt: Date(
                    timeIntervalSince1970: TimeInterval(latestVersion.createdAt) / 1_000
                ),
                lastRunAt: app.lastRunAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                }
            )
        }

        return HomeContinueCardModel.resolve(
            novelProjects: novelProjects,
            councilTask: councilTask,
            deepReadTasks: deepReadTasks,
            miniApps: miniApps,
            imageGeneration: imageGeneration
        )
    }

    private var controlCard: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        return VStack(spacing: 0) {
            if let model = homeContinueModel {
                VStack(spacing: 0) {
                    HomeContinueButton(model: model) { destination in
                        switch destination {
                        case .openCouncil: router.navigate(to: .council)
                        case .deepReadTask(let id): router.navigate(to: .deepReadTask(id: id))
                        case .resumeProject(let id): router.navigate(to: .novelProject(id: id))
                        case .miniAppRunner(let id): router.navigate(to: .miniAppRunner(appId: id))
                        case .generatedImage(let anchor):
                            openGeneratedImage(anchor)
                        }
                    }
                    Rectangle().fill(AmberTheme.separator).frame(height: 1 / displayScale).padding(.horizontal, 16)
                        .accessibilityHidden(true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            shortcutRow
        }
        // Continue 候选出现/消失：高度随 VStack 收放 + opacity（taste：离散状态 0.3s，非 spring 列表）。
        .animation(homeContinuePresenceMotion, value: homeContinueModel)
        .background {
            ZStack {
                AmberTheme.card
                // Pi/sit：卡内淡网格，避免只有露边画布有纹理、卡面一片板。
                HomeCardCanvasTexture()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius).strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
        .padding(.horizontal, 16).padding(.top, 20)
    }

    @ViewBuilder
    private var shortcutRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) {
                HStack(spacing: 0) { shortcutButtons }
                    .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .padding(.vertical, 9)
            .padding(.bottom, 2)
        } else {
            HStack(spacing: 0) { shortcutButtons }
                .padding(.vertical, 9)
                .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        HomeShortcut(entry: .deepRead) { router.navigate(to: .board) }
            .accessibilityFocused($deepReadShortcutFocused)
        HomeShortcut(entry: .novel) { router.navigate(to: .novelCreation) }
        HomeShortcut(entry: .council) { router.navigate(to: .council) }
        HomeShortcut(entry: .miniApps) { router.navigate(to: .miniApps) }
        HomeShortcut(entry: .webMount) { router.navigate(to: .webMount) }
    }

    private func announceHomeContinueChange(
        from oldValue: HomeContinueCardModel?,
        to newValue: HomeContinueCardModel?
    ) {
        guard router.path.isEmpty,
              UIAccessibility.isVoiceOverRunning,
              oldValue != newValue else { return }
        if newValue == nil {
            deepReadShortcutFocused = true
        }
        let announcement = newValue.map {
            IOSAppLocalization.formatted(
                "待继续任务更新：%@，%@，%@",
                defaultValue: "待继续任务更新：%@，%@，%@",
                arguments: [$0.title, $0.meta, $0.ctaTitle]
            )
        } ?? IOSAppLocalization.string("没有待继续任务", defaultValue: "没有待继续任务")
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func openGeneratedImage(_ anchor: ChatMessageAnchor) {
        guard let conversationID = conversationStore.summaries.first(where: {
            $0.id.toHexDashString() == anchor.conversationID
        })?.id else {
            homeImageGenerationContext = nil
            homeContinueError = "图片所在会话已不存在。"
            return
        }
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard chatViewModel.prepareForConversationChange(to: conversationID) else {
                homeContinueError = "当前生成任务暂时无法切换会话，请稍后重试。"
                return
            }
            if conversationStore.currentConversation?.id != conversationID {
                guard await conversationStore.selectConversationIfAvailable(
                    id: conversationID,
                    commitIf: { !Task.isCancelled }
                ) else {
                    guard !Task.isCancelled else { return }
                    homeImageGenerationContext = nil
                    homeContinueError = "图片所在会话已不存在。"
                    return
                }
            }
            guard !Task.isCancelled,
                  conversationStore.currentConversation?.id == conversationID,
                  let toolCallID = anchor.toolCallID else {
                homeContinueError = "无法切换到图片所在会话。"
                return
            }

            guard let context = ChatImageGenerationResumeProjection.matching(
                in: conversationStore.currentMessages,
                conversationID: anchor.conversationID,
                messageID: anchor.messageID,
                toolCallID: toolCallID,
                isGenerationActive: chatViewModel.isGenerationActive(conversationId: conversationID)
            ) else {
                homeImageGenerationContext = nil
                homeContinueError = "图片记录已不存在或生成没有成功。"
                return
            }

            router.navigate(to: .chatMessage(anchor: ChatMessageAnchor(
                conversationID: context.conversationID,
                messageID: context.messageID,
                toolCallID: context.toolCallID
            )))
        }
    }

    private func exportConversation(id: KotlinUuid, title: String, format: IOSConversationExportFormat) {
        Task { @MainActor in
            await IOSConversationExporter.share(format: format, title: title) {
                // 存储层的错误弹窗只挂在聊天页，会话列表上看不到，所以这里始终由浮层给出提示。
                guard let messages = await conversationStore.messages(for: id) else {
                    return .failed("无法读取这段对话，可能已被删除或读取失败。")
                }
                return .loaded(messages)
            }
        }
    }

    private func openConversation(_ conversationID: KotlinUuid) {
        collapseSearchIfNeeded()
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard chatViewModel.prepareForConversationChange(to: conversationID) else { return }
            if conversationStore.currentConversation?.id != conversationID {
                guard await conversationStore.selectConversationIfAvailable(
                    id: conversationID,
                    commitIf: { !Task.isCancelled }
                ) else {
                    guard !Task.isCancelled else { return }
                    homeContinueError = "该会话暂时无法打开。"
                    return
                }
            }
            guard !Task.isCancelled,
                  conversationStore.currentConversation?.id == conversationID else { return }
            router.navigate(to: .chat)
        }
    }

    private func startNewConversation() {
        collapseSearchIfNeeded()
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard await chatViewModel.startNewConversation(
                commitIf: { !Task.isCancelled }
            ) else { return }
            guard !Task.isCancelled else { return }
            router.navigate(to: .chat)
        }
    }
}

/// 真实会话摘要行：切片一体卡（外框 + 顶/底投影），激活行 accent 色带，行间 hairline。
/// 非 private（原为 private struct）：只放宽到 internal，方便 HomeDesignContractTests
/// 用 @testable import 直接构造实例验证 `==`；仍是模块内部类型，不对外暴露。
