import SwiftUI
import Shared

struct SearchServicesView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var draggingProviderId: String?

    var body: some View {
        // 关键:读一次被观察的 revision 建立依赖。snapshot 是 @ObservationIgnored,直接读
        // sharedSettings.enableWebSearch 等不会触发本页刷新,会导致开关「点了没反应」(bug①)。
        let _ = sharedSettings.revision

        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 20) {
                        masterSection
                        builtinSourcesSection
                        configuredSection
                        commonOptionsSection
                        recommendedSection
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("搜索服务")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            AmberGlassCircleButton(systemImage: "plus", accessibilityLabel: "添加搜索服务", size: 44, symbolSize: 17) {
                router.navigate(to: .searchProvider)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Master (Agent web search)

    private var masterSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Agent 网络搜索")

            AmberFormGroup {
                SearchPresetToggleRow(
                    title: "Agent 网络搜索",
                    subtitle: "允许聊天调用 search_web 和 scrape_web，使用已启用的服务。",
                    isOn: sharedSettings.enableWebSearch
                ) { enabled in
                    sharedSettings.setEnableWebSearch(enabled)
                }

                SearchServicesDivider()

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusActive ? AmberTheme.accentGreen : AmberTheme.muted2)
                        .frame(width: 8, height: 8)
                    Text("\(totalEnabledCount) / \(totalServiceCount) 项已开启")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40)
                .padding(.horizontal, 14)
            }
        }
    }

    private var statusActive: Bool {
        sharedSettings.enableWebSearch && IOSSearchExecutor.searchProviderSelection(settings: sharedSettings.snapshot).route != .unsupported
    }

    // MARK: - Built-in free sources

    private var builtinSourcesSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "内置免费源")

            AmberFormGroup {
                builtinRow(
                    title: IOSFreeSearchAggregator.providerName,
                    subtitle: "无需 Key，同时查询 Bing、Brave、DuckDuckGo、夸克、360、维基百科等，单个源失败或遇验证页自动跳过。",
                    isOn: sharedSettings.searchBuiltinDuckDuckGoEnabled || sharedSettings.searchBuiltinBingEnabled
                ) {
                    sharedSettings.setSearchBuiltinDuckDuckGoEnabled($0)
                    sharedSettings.setSearchBuiltinBingEnabled($0)
                }
                SearchServicesDivider()
                builtinRow(
                    title: "Jina Reader 读全文",
                    subtitle: "网页直连读取失败（如知乎 403）时，改由 Jina Reader 代读正文；无需 Key，有频率限制。",
                    isOn: sharedSettings.searchBuiltinJinaEnabled
                ) { sharedSettings.setSearchBuiltinJinaEnabled($0) }
                SearchServicesDivider()
                builtinRow(
                    title: "Google WebView 兜底",
                    subtitle: "免费聚合结果不足时，在后台网页中打开 Google 搜索补充结果；已有足够结果时跳过。",
                    isOn: sharedSettings.searchGoogleWebViewFallbackEnabled
                ) { sharedSettings.setSearchGoogleWebViewFallbackEnabled($0) }
            }
        }
    }

    private func builtinRow(
        title: String,
        subtitle: String,
        isOn: Bool,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        SearchPresetToggleRow(title: title, subtitle: subtitle, isOn: isOn, onToggle: onToggle)
    }

    // MARK: - Configured custom providers

    private var configuredSection: some View {
        VStack(spacing: 0) {
            HStack {
                AmberSectionLabel(text: "已配置")
                Spacer()
                if configuredProviders.count > 1 {
                    Label("拖动调整候补顺序", systemImage: "arrow.up.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted2)
                        .padding(.trailing, 16)
                        .padding(.bottom, 6)
                }
            }

            Text("点服务名称设为默认。默认服务关闭、缺少 Key 或暂不支持时，按此顺序选择其他可用服务。请求失败时，仅在免费聚合开启时回退免费搜索。")
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            AmberFormGroup {
                if configuredProviders.isEmpty {
                    Text("暂无自定义搜索服务。点右上角「+」可添加已接入的搜索服务作为聊天默认搜索。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                } else {
                    ForEach(Array(configuredProviders.enumerated()), id: \.element.id) { offset, provider in
                        if offset > 0 { SearchServicesDivider(leading: 52) }
                        configuredRow(provider)
                    }
                }
            }
        }
    }

    private func configuredRow(_ provider: IOSConfiguredSearchProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
                .frame(width: 24)

            ZStack {
                Circle().fill(AmberTheme.accent.opacity(0.12)).frame(width: 22, height: 22)
                Text("\(provider.index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AmberTheme.accent)
            }

            Button {
                sharedSettings.selectSearchProvider(serviceId: provider.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(provider.selected ? "\(provider.typeLabel) · 默认" : provider.typeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(provider.selected ? AmberTheme.accent : AmberTheme.muted2)
                    if provider.isFreeAggregate {
                        Text("受上方免费聚合开关控制")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.name)，\(provider.selected ? "默认搜索服务" : "设为默认搜索服务")")

            Toggle("启用\(provider.name)", isOn: Binding(
                get: { provider.enabled },
                set: { sharedSettings.setSearchProviderEnabled(serviceId: provider.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(AmberTheme.accent)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .opacity(draggingProviderId == provider.id ? 0.4 : 1)
        .draggable(provider.id) {
            Text(provider.name)
                .font(.body.weight(.semibold))
                .padding(8)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let draggedId = items.first else { return false }
            moveProvider(draggedId: draggedId, ontoIndex: provider.index)
            return true
        } isTargeted: { targeted in
            draggingProviderId = targeted ? provider.id : (draggingProviderId == provider.id ? nil : draggingProviderId)
        }
    }

    private func moveProvider(draggedId: String, ontoIndex: Int) {
        draggingProviderId = nil
        guard let from = configuredProviders.first(where: { $0.id == draggedId })?.index,
              from != ontoIndex else { return }
        sharedSettings.moveSearchProvider(fromIndex: from, toIndex: ontoIndex)
    }

    // MARK: - Common options (result count)

    private var commonOptionsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "通用选项")

            AmberFormGroup {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("结果数量")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("每次搜索最多返回的结果条数")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    resultCountStepper
                }
                .frame(minHeight: 56)
                .padding(.horizontal, 14)
            }
        }
    }

    private var resultCountStepper: some View {
        HStack(spacing: 0) {
            stepperButton(systemImage: "minus", enabled: sharedSettings.searchResultSize > 1) {
                sharedSettings.setSearchResultSize(sharedSettings.searchResultSize - 1)
            }
            Text("\(sharedSettings.searchResultSize)")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 38)
            stepperButton(systemImage: "plus", enabled: sharedSettings.searchResultSize < 10) {
                sharedSettings.setSearchResultSize(sharedSettings.searchResultSize + 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private func stepperButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? AmberTheme.accent : AmberTheme.muted2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Recommended combos

    private var recommendedSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "推荐组合")

            AmberFormGroup {
                recommendedRow(title: "零成本", detail: "免费聚合搜索 + Jina Reader")
                SearchServicesDivider()
                recommendedRow(title: "Google 结果", detail: "Serper / SerpAPI")
                SearchServicesDivider()
                recommendedRow(title: "高质量多源", detail: "Tavily 或 Brave")
            }
        }
    }

    private func recommendedRow(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground2)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
    }

    // MARK: - Derived data

    private var configuredProviders: [IOSConfiguredSearchProvider] {
        sharedSettings.configuredSearchProviders
    }

    private var builtinEnabledCount: Int {
        [
            sharedSettings.searchBuiltinDuckDuckGoEnabled || sharedSettings.searchBuiltinBingEnabled,
            sharedSettings.searchBuiltinJinaEnabled,
            sharedSettings.searchGoogleWebViewFallbackEnabled,
        ].lazy.filter { $0 }.count
    }

    private var totalEnabledCount: Int {
        builtinEnabledCount + configuredProviders.lazy.filter { $0.enabled }.count
    }

    private var totalServiceCount: Int {
        3 + configuredProviders.count
    }
}

private struct SearchServicesDivider: View {
    var leading: CGFloat = 14

    var body: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, leading)
    }
}

private struct SearchPresetToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    var onToggle: ((Bool) -> Void)?

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { value in onToggle?(value) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(AmberTheme.accent)
        .disabled(onToggle == nil)
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityLabel("\(title)\(isOn ? "，开启" : "，关闭")")
    }
}

#Preview {
    NavigationStack {
        SearchServicesView(sharedSettings: IOSSharedSettingsStore())
            .environment(RouterPath())
    }
}
