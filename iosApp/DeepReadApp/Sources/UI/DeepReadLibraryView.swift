import SwiftUI

struct DeepReadLibraryView: View {
    let settings: DeepReadSettingsStore
    let runtime: DeepReadRuntime
    @State private var query = ""
    @State private var status: IOSDeepReadTaskStatus?
    @State private var presentingCreate = false
    @State private var selectedTaskId: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    @Namespace private var filter

    private var visibleTasks: [IOSDeepReadTask] {
        runtime.store.history.filter { task in
            (status == nil || task.status == status)
                && (query.isEmpty || task.title.localizedStandardContains(query)
                    || task.resultMarkdown.localizedStandardContains(query))
        }
    }

    var body: some View {
        let tasks = visibleTasks
        let still = reduceMotion
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                filterBar
                if tasks.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty && status == nil ? "你的阅读库" : "没有匹配的文章",
                        systemImage: "books.vertical",
                        description: Text(query.isEmpty && status == nil ? "从一个主题、一段文字或几个来源开始。" : "尝试其他关键词或状态。")
                    )
                    .symbolEffect(.bounce, options: .nonRepeating, value: status)
                    .padding(.top, 40)
                } else {
                    ForEach(tasks) { task in
                        NavigationLink {
                            DeepReadDetailView(taskId: task.id, settings: settings, runtime: runtime)
                                .navigationTransition(.zoom(sourceID: task.id, in: zoom))
                        } label: { card(task) }
                        .buttonStyle(DeepReadPressableStyle())
                        .matchedTransitionSource(id: task.id, in: zoom)
                        .scrollTransition { card, phase in
                            card.opacity(phase.isIdentity || still ? 1 : 0.5)
                                .scaleEffect(phase.isIdentity || still ? 1 : 0.95)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .modifier(DeepReadTabVisibility())
        .background { DeepReadPaperBackground(night: DeepReadMoment.isNight(.now)) }
        .navigationTitle("阅读库")
        .searchable(text: $query, prompt: "搜索标题与正文")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("创建", systemImage: "square.and.pencil") { presentingCreate = true }
                    .accessibilityIdentifier("deepread.library.create")
            }
        }
        .sheet(isPresented: $presentingCreate) {
            NavigationStack {
                DeepReadComposerView(settings: settings, runtime: runtime) { selectedTaskId = $0 }
            }
        }
        .navigationDestination(item: $selectedTaskId) { id in
            DeepReadDetailView(taskId: id, settings: settings, runtime: runtime)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", value: nil)
                ForEach(IOSDeepReadTaskStatus.allCases, id: \.self) { chip($0.title, value: $0) }
            }
        }
        // Chips scroll edge to edge but rest on the page margin, keeping the margin tappable.
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .padding(.horizontal, -18)
        .sensoryFeedback(.selection, trigger: status)
    }

    private func chip(_ title: String, value: IOSDeepReadTaskStatus?) -> some View {
        let selected = status == value
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { status = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? DeepReadPalette.paper : DeepReadPalette.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule().fill(DeepReadPalette.accent).matchedGeometryEffect(id: "chip", in: filter)
                    } else {
                        Capsule().strokeBorder(DeepReadPalette.rule)
                    }
                }
                .padding(.vertical, 6) // 44pt tap height around the 32pt capsule
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func card(_ task: IOSDeepReadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DeepReadStatusChip(task: task, active: runtime.activeTaskIds.contains(task.id))
                Spacer()
                Text(Date(timeIntervalSince1970: Double(task.createdAt) / 1000)
                    .formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
                    .font(.caption).foregroundStyle(DeepReadPalette.muted)
            }
            Text(task.title).font(.system(.title3, design: .serif).weight(.medium))
                .foregroundStyle(DeepReadPalette.ink).multilineTextAlignment(.leading)
            Text(task.sourceSummary).font(.caption).foregroundStyle(DeepReadPalette.muted).lineLimit(2)
            if let failure = runtime.error(for: task.id) {
                Text(failure).font(.caption).foregroundStyle(DeepReadPalette.danger).lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deepReadCard()
    }
}

struct DeepReadStatusChip: View {
    let task: IOSDeepReadTask
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let partial = !(task.missingSections ?? []).isEmpty
        let tint: Color = switch task.status {
        case .succeeded: partial ? DeepReadPalette.warn : DeepReadPalette.done
        case .running, .queued: DeepReadPalette.warn
        case .failed, .unsupported: DeepReadPalette.danger
        }
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .phaseAnimator(active && !reduceMotion ? [1.0, 0.25] : [1.0]) { dot, value in dot.opacity(value) }
                    animation: { _ in .easeInOut(duration: 0.7) }
            Text(partial ? "\(task.status.title) · 部分章节待补全" : task.status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.11), in: .capsule)
    }
}
