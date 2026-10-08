import SwiftUI
@preconcurrency import Shared
@preconcurrency import Network

struct DeepReadDiscoveryView: View {
    let settings: DeepReadSettingsStore
    let runtime: DeepReadRuntime
    @State private var dashboard = IOSHotListDashboardStore.shared
    @State private var preferences = DeepReadDiscoveryPreferences.shared
    @State private var presentingCreate = false
    @State private var selectedTaskId: String?
    @State private var zoomSource: String?
    @State private var error: String?
    @State private var listShown = false
    @State private var scatter = 0
    @State private var scattered = false
    @State private var lucky: LuckyPick?
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom

    private struct LuckyPick: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let zoomID: String
        let sources: () throws -> [IOSDeepReadSource]
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                DeepReadMasthead(issue: runtime.store.tasks.count + 1)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).deepReadCard()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                content
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: error)
        }
        .modifier(DeepReadTabVisibility())
        .background { DeepReadPaperBackground(night: DeepReadMoment.isNight(.now)) }
        .navigationTitle("深度阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DeepReadDiscoverySettingsView() } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("热点来源设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("创建阅读", systemImage: "square.and.pencil") { presentingCreate = true }
                    .accessibilityIdentifier("deepread.discovery.create")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let lucky { luckyBanner(lucky).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .sensoryFeedback(.success, trigger: lucky) { _, new in new != nil }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: .deepReadDeviceShaken)) { _ in if visible && !presentingCreate { shuffle() } }
        .task(id: lucky?.id) {
            guard lucky != nil else { return }
            // A newer pick cancels this task; don't clear it.
            guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
            withAnimation(.snappy) { lucky = nil }
        }
        .refreshable { await refresh(force: true) }
        .task(id: preferences.configuration) { await refresh(force: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh(force: false) } }
        }
        .onChange(of: dashboard.dashboard.hasContent, initial: true) { _, has in
            if has { listShown = true }
        }
        .sheet(isPresented: $presentingCreate) {
            NavigationStack {
                DeepReadComposerView(settings: settings, runtime: runtime) { id in
                    // A zoom from the toolbar button left the article's own toolbar empty; push plainly instead.
                    zoomSource = nil
                    selectedTaskId = id
                }
            }
        }
        .navigationDestination(item: $selectedTaskId) { id in
            DeepReadDetailView(taskId: id, settings: settings, runtime: runtime)
                .navigationTransition(.zoom(sourceID: zoomSource ?? id, in: zoom))
        }
    }

    @ViewBuilder private var content: some View {
        if dashboard.isRefreshing && !dashboard.dashboard.hasContent {
            ForEach(0..<3, id: \.self) { _ in placeholderCard }
        } else if !dashboard.dashboard.hasContent {
            ContentUnavailableView("暂无热点", systemImage: "newspaper",
                description: Text(preferences.configuration.enabledSources.isEmpty ? "在热点来源中启用榜单，或直接创建阅读。" : "下拉刷新，或从自己的主题开始阅读。"))
                .symbolEffect(.wiggle, options: .nonRepeating)
                .padding(.top, 30)
        }
        if !dashboard.dashboard.topics.isEmpty {
            DeepReadSectionHeader(title: "多来源热点", detail: "多个榜单都在讨论")
                .deepReadEntrance(0, shown: listShown)
            ForEach(Array(dashboard.dashboard.topics.enumerated()), id: \.element.id) { index, topic in
                let sources = { try IOSDeepReadSourceNormalizer.hotTopicSources(topic: topic) }
                Button {
                    start(topic.title, zoomID: topic.id, sources: sources)
                } label: { topicCard(topic, index: index) }
                .buttonStyle(DeepReadPressableStyle())
                .contextMenu { modeMenu(topic.title, zoomID: topic.id, sources: sources) }
                .matchedTransitionSource(id: topic.id, in: zoom)
                .deepReadEntrance(index + 1, shown: listShown)
                .modifier(Scatter(index: index, seed: scatter, active: scattered))
            }
        }
        ForEach(Array(dashboard.dashboard.providers.enumerated()), id: \.element.id) { index, provider in
            providerBlock(provider)
                .deepReadEntrance(dashboard.dashboard.topics.count + index + 1, shown: listShown)
                .modifier(Scatter(index: index + 40, seed: scatter, active: scattered))
        }
    }

    private func topicCard(_ topic: IOSHotTopic, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 22, weight: .light, design: .serif)).monospacedDigit()
                .foregroundStyle(DeepReadPalette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title).font(.system(.headline, design: .serif))
                    .foregroundStyle(DeepReadPalette.ink).multilineTextAlignment(.leading)
                    .lineLimit(3)
                Text(sourceSummary(for: topic))
                    .font(.caption).foregroundStyle(DeepReadPalette.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold))
                .foregroundStyle(DeepReadPalette.muted)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deepReadCard()
    }

    private func providerBlock(_ provider: IOSHotListProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.providerName).font(.system(.headline, design: .serif)).foregroundStyle(DeepReadPalette.ink)
                Spacer()
                if provider.stale {
                    Label("上次内容", systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(DeepReadPalette.muted)
                }
            }
            .padding(.bottom, 8)
            if let failure = provider.error {
                Text(failure).font(.caption).foregroundStyle(DeepReadPalette.muted).padding(.bottom, 6)
            }
            if provider.stale {
                Text("暂时无法更新，显示上次取得的内容。")
                    .font(.caption).foregroundStyle(DeepReadPalette.muted).padding(.bottom, 6)
            }
            ForEach(Array(provider.items.enumerated()), id: \.offset) { offset, item in
                if offset > 0 { Rectangle().fill(DeepReadPalette.rule).frame(height: 0.6) }
                let zoomID = "\(provider.id)|\(item.rank)"
                let sources = { [itemSource(item, provider: provider)] }
                Button {
                    start(item.presentationTitle, zoomID: zoomID, sources: sources)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(item.rank))
                            .font(.system(.callout, design: .serif).weight(item.rank <= 3 ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(item.rank <= 3 ? DeepReadPalette.accent : DeepReadPalette.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(minWidth: 26)
                        Text(item.presentationTitle).foregroundStyle(DeepReadPalette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(DeepReadPressableStyle())
                .contextMenu { modeMenu(item.presentationTitle, zoomID: zoomID, sources: sources) }
                .matchedTransitionSource(id: zoomID, in: zoom)
            }
        }
        .padding(14)
        .deepReadCard()
    }

    private var placeholderCard: some View {
        topicCard(IOSHotTopic(id: "placeholder", title: "正在获取今天的热点话题", sources: [], sourceCount: 3, bestRank: 1, latestFetchedAt: 0), index: 0)
            .redacted(reason: .placeholder)
            .phaseAnimator(reduceMotion ? [1.0] : [0.45, 1.0]) { view, opacity in view.opacity(opacity) }
                animation: { _ in .easeInOut(duration: 0.9) }
            .accessibilityLabel("正在获取热点")
    }

    private func luckyBanner(_ pick: LuckyPick) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "dice").font(.title2).foregroundStyle(DeepReadPalette.accent)
                .symbolEffect(.bounce, value: pick.id)
            VStack(alignment: .leading, spacing: 3) {
                Text("摇到一篇 · \(pick.detail)").font(.caption).foregroundStyle(DeepReadPalette.muted)
                Text(pick.title).font(.system(.subheadline, design: .serif).weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("读这篇") {
                withAnimation(.snappy) { lucky = nil }
                start(pick.title, zoomID: pick.zoomID, sources: pick.sources)
            }
            .buttonStyle(.glassProminent)
            .fixedSize()
            Button("关闭", systemImage: "xmark") { withAnimation(.snappy) { lucky = nil } }
                .labelStyle(.iconOnly).buttonStyle(.glass)
                .fixedSize()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 760)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    // MARK: Actions

    private enum StartMode { case auto, closeReading, originalOnly, synthesis }

    /// Article-like entries open as a close reading of their best-ranked article (with the
    /// topic's other sources as other reports); discussions (Zhihu, Weibo, Bilibili) stay a synthesis.
    private func start(_ title: String, zoomID: String, mode: StartMode = .auto, sources: () throws -> [IOSDeepReadSource]) {
        do {
            let list = try sources()
            let primary = mode == .synthesis ? nil : DeepReadCloseReader.primaryIndex(in: list)
            let id = try runtime.create(title: title, sources: list, primaryIndex: primary, originalOnly: mode == .originalOnly)
            zoomSource = zoomID
            selectedTaskId = id
        } catch { self.error = IOSDeepReadUserFacingText.fromError(error) }
    }

    @ViewBuilder
    private func modeMenu(_ title: String, zoomID: String, sources: @escaping () throws -> [IOSDeepReadSource]) -> some View {
        if DeepReadCloseReader.primaryIndex(in: (try? sources()) ?? []) != nil {
            Button("精读原文", systemImage: "doc.text.magnifyingglass") { start(title, zoomID: zoomID, mode: .closeReading, sources: sources) }
            Button("只读原文", systemImage: "doc.plaintext") { start(title, zoomID: zoomID, mode: .originalOnly, sources: sources) }
        }
        Button("多源综述", systemImage: "square.stack.3d.up") { start(title, zoomID: zoomID, mode: .synthesis, sources: sources) }
    }

    private func itemSource(_ item: IOSHotlistItem, provider: IOSHotListProviderSnapshot) -> IOSDeepReadSource {
        IOSDeepReadSource(kind: .hotTopic, title: item.presentationTitle,
            content: "\(item.title)\n来源：\(provider.providerName)\n排名：\(item.rank)", url: item.url,
            metadata: ["provider_id": provider.providerId, "provider_name": provider.providerName, "rank": String(item.rank)])
    }

    /// Shake easter egg: the page scatters like a tossed newspaper, then lands on a random story.
    private func shuffle() {
        let board = dashboard.dashboard
        var picks: [LuckyPick] = board.topics.map { topic in
            LuckyPick(title: topic.title, detail: "\(topic.sourceCount) 个来源", zoomID: topic.id) {
                try IOSDeepReadSourceNormalizer.hotTopicSources(topic: topic)
            }
        }
        for provider in board.providers {
            for item in provider.items {
                picks.append(LuckyPick(title: item.presentationTitle, detail: "\(provider.providerName) 第 \(item.rank)",
                    zoomID: "\(provider.id)|\(item.rank)") { [itemSource(item, provider: provider)] })
            }
        }
        guard let pick = picks.randomElement(), !scattered else { return }
        guard !reduceMotion else { withAnimation(.easeInOut) { lucky = pick }; return }
        scatter += 1
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { scattered = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            withAnimation(.spring(response: 0.62, dampingFraction: 0.66)) {
                scattered = false
                lucky = pick
            }
        }
    }

    private func sourceSummary(for topic: IOSHotTopic) -> String {
        var names: [String] = []
        for source in topic.sources where !names.contains(source.providerName) {
            names.append(source.providerName)
        }
        return "\(topic.sourceCount) 个来源 · \(names.joined(separator: "、"))"
    }

    private func refresh(force: Bool) async {
        error = nil
        let setting = preferences.boardSetting
        if setting.hotListWifiOnly, !(await wifiAvailable()) {
            error = "已开启仅 Wi-Fi 刷新，当前热点尚未更新。"
            return
        }
        var translate: IOSHotListTitleTranslate?
        if setting.hotListTranslateToChinese, let resolved = settings.resolvedModel {
            translate = { titles in
                await IOSHotListTitleTranslator.translate(titles: titles, providerSetting: resolved.provider, modelId: resolved.model.modelId)
            }
        }
        await dashboard.refresh(setting: setting, force: force, translate: translate)
        error = dashboard.lastError
    }

    private func wifiAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                monitor.pathUpdateHandler = nil
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "app.amber.deepread.wifi"))
        }
    }
}

/// Deterministic toss offsets so each shake lands differently but every card returns home.
private struct Scatter: ViewModifier {
    let index: Int
    let seed: Int
    let active: Bool

    func body(content: Content) -> some View {
        var hasher = Hasher()
        hasher.combine(index)
        hasher.combine(seed)
        let bits = UInt64(bitPattern: Int64(hasher.finalize()))
        func unit(_ shift: UInt64) -> Double { Double((bits >> shift) & 0xFF) / 127.5 - 1 }
        return content
            .offset(x: active ? unit(0) * 70 : 0, y: active ? unit(8) * 36 - 18 : 0)
            .rotationEffect(.degrees(active ? unit(16) * 9 : 0))
    }
}

/// Newspaper masthead: issue number, date line, seasonal ribbon, and the headline seal easter egg.
private struct DeepReadMasthead: View {
    let issue: Int
    @State private var shown = false
    @State private var taps: [Date] = []
    @State private var seal: Int?
    @State private var slam = 0
    @ScaledMetric(relativeTo: .title) private var headlineSize: CGFloat = 28
    private let inscriptions = ["深读", "慢读", "求真", "存疑", "博观", "约取"]

    var body: some View {
        let now = Date.now
        let festival = DeepReadMoment.festival(on: now)
        let night = DeepReadMoment.isNight(now)
        let dateline = HStack(spacing: 8) {
            Text(String(format: "No.%03d", issue)).monospacedDigit()
                .contentTransition(.numericText(value: Double(issue)))
            Text(now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
        }
        .fixedSize()
        .font(.caption.weight(.medium)).foregroundStyle(DeepReadPalette.muted)
        let badges = HStack(spacing: 6) {
            if night { badge("夜读", symbol: "moon.stars.fill", tint: DeepReadPalette.warn) }
            if let festival { badge(festival.name, symbol: festival.symbol, tint: DeepReadPalette.accent) }
        }
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(DeepReadPalette.ink).frame(height: 2.5)
                .scaleEffect(x: shown ? 1 : 0, anchor: .leading)
            // One line when it fits; badges drop below at narrow widths or large text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { dateline; Spacer(minLength: 0); badges }
                VStack(alignment: .leading, spacing: 6) { dateline; badges }
            }
            Text("把热点读深一点")
                .font(.system(size: headlineSize, weight: .semibold, design: .serif))
                .foregroundStyle(DeepReadPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: tapHeadline)
                .overlay(alignment: .trailing) {
                    if let seal {
                        DeepReadInkStamp(text: inscriptions[seal], size: 46)
                            .modifier(DeepReadStampSlam(trigger: slam))
                            .offset(x: -6)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.top, 4)
        // The headline grows with Dynamic Type but stops before it wraps under the seal.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: slam)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = true } }
    }

    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DeepReadPalette.ink)
            .labelStyle(TintedIconLabelStyle(tint: tint))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .symbolEffect(.bounce, options: .nonRepeating, value: shown)
    }

    /// Five quick taps press a seal; each later tap re-inks a new inscription.
    private func tapHeadline() {
        if let current = seal {
            seal = (current + 1) % inscriptions.count
            slam += 1
            return
        }
        let now = Date.now
        taps = taps.filter { now.timeIntervalSince($0) < 1.6 } + [now]
        if taps.count >= 5 {
            taps = []
            seal = 0
            slam += 1
        }
    }
}

struct DeepReadSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(DeepReadPalette.ink)
            if let detail { Text(detail).font(.caption).foregroundStyle(DeepReadPalette.muted) }
            Rectangle().fill(DeepReadPalette.rule).frame(height: 0.8).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Colors only the icon so badge text keeps full contrast.
private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
