import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared
struct IOSDeepReadTaskDetailView: View {
    let taskId: String
    var settingsStore: SettingsStore? = nil
    var sharedSettings: IOSSharedSettingsStore? = nil
    var providerRegistry: ProviderRegistryStore? = nil

    @State private var store = IOSDeepReadStore.shared
    @State private var templateStore = IOSDeepReadTemplateStore.shared
    @State private var toast: String?
    @State private var statusPulse = false
    /// Start small so WKWebView contentSize / JS measure can grow to true article
    /// height. A large default (e.g. 600) freezes a short article inside a tall frame
    /// and leaves a blank gap above「相关报道」.
    @State private var editorialHeight: CGFloat = 1
    @State private var isRetryingWorkspaceSync = false
    /// Decoded once per task change; the body and header read them many times per update.
    @State private var closeReading: DeepReadCloseReading?
    @State private var templateArticle: DeepReadTemplateArticle?
    /// Nil follows the article: original when it has no guide yet, close reading otherwise.
    @State private var originalChoice: Bool?
    /// The `structuredJSON` the two values above were decoded from. The article waits until they
    /// match the task: loading one page and replacing it a frame later makes the reader drop the second.
    @State private var decodedJSON: String?? = .none
    @Bindable private var appearance = DeepReadAppearance.shared
    @State private var press: PressMoment?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(\.dismiss) private var dismiss

    private var task: IOSDeepReadTask? {
        store.task(id: taskId)
    }

    private var showsOriginal: Bool { closeReading.map { originalChoice ?? !$0.hasGuide } ?? false }

    private struct PressMoment: Equatable {
        let inscription: String
        let caption: String
    }

    // 三种 UI 状态:生成中(骨架)/ 完成(编辑器正文)/ 失败(琥珀横幅)。心智:阅读面是实的,
    // 控制面才是玻璃。masthead + 状态机 + 骨架 + 失败横幅 + 来源折叠 + 底栏均为原生 SwiftUI;
    // 正文沿用编辑器 HTML 渲染器(自带衬线/首字下沉),并切到 body-only 由 masthead 提供标题。
    private enum DetailState { case generating, done, failed }

    private func state(for task: IOSDeepReadTask) -> DetailState {
        if task.status == .failed || task.status == .unsupported { return .failed }
        if task.status == .queued || task.status == .running { return .generating }
        if !task.resultMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .done }
        return .generating
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmberThemePageBackground(surface: .app)

            ScrollView {
                VStack(spacing: 0) {
                    if let task, state(for: task) == .done, let cover = coverImageURL(task) {
                        // 头图作为封面满溢到顶部(浮动顶栏在其上方半透叠加),标题在其下方。
                        coverImage(url: cover)
                    } else {
                        // 无封面:内容从浮动顶栏下方开始,向上滚动时从渐变模糊顶栏下穿过。
                        // 留足高度让 kicker(EVENT)落在返回按钮下方、不顶到它。
                        Color.clear.frame(height: 70)
                    }

                    if let task {
                        masthead(task)
                        if store.persistenceError(for: task.id) != nil, state(for: task) == .done {
                            failBanner(task)
                        }
                        workspaceSyncBanner(task)
                        partialSectionsBanner(task)
                        content(task)
                        sourcesSection(task)
                        Color.clear.frame(height: state(for: task) == .done ? 24 : 36)
                    } else {
                        Text("这条深度阅读历史无法读取。")
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.hidden)

            header
            toastView
        }
        .overlay {
            if let press {
                IOSDeepReadPressMoment(inscription: press.inscription, caption: press.caption)
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut) { self.press = nil } }
            }
        }
        .task(id: press) {
            guard let press else { return }
            // A replaced or dismissed seal cancels this task; don't clear its successor.
            guard (try? await Task.sleep(for: .seconds(press.inscription == "付印" ? 1.4 : 2.6))) != nil else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.press = nil }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { statusPulse = true }
        }
        .onChange(of: taskId) { _, _ in
            editorialHeight = 1
            originalChoice = nil
        }
        .onChange(of: task, initial: true) { old, task in
            closeReading = DeepReadCloseReading.decode(task?.structuredJSON)
            templateArticle = closeReading == nil ? DeepReadTemplateArticle.decode(task?.structuredJSON) : nil
            decodedJSON = .some(task?.structuredJSON)
            // A run that finished while the reader watched. A retry that only restored the
            // previous article after a failure leaves the text unchanged and is not a fresh print.
            guard let old, let new = task, old.id == new.id, old.status == .running || old.status == .queued, new.status == .succeeded,
                  new.resultMarkdown != old.resultMarkdown,
                  let seal = DeepReadMoment.pressSeal(
                    finishedWithError: false,
                    wasFirstDraft: old.resultMarkdown.isEmpty,
                    completedCount: store.tasks.filter { $0.status == .succeeded }.count)
            else { return }
            withAnimation(.easeIn(duration: 0.2)) { press = PressMoment(inscription: seal.inscription, caption: seal.caption) }
        }
        .sensoryFeedback(.selection, trigger: originalChoice)
        .sensoryFeedback(.selection, trigger: appearance.readerStyle)
        .sensoryFeedback(.selection, trigger: appearance.readerLayout)
    }

    // 浮动玻璃顶栏:返回左对齐,操作组右对齐(完成→分享,失败→重试)。底部渐变模糊。
    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回深度阅读", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            if let task {
                switch state(for: task) {
                case .failed:
                    AmberGlassCircleButton(systemImage: "arrow.clockwise", accessibilityLabel: "重试深度阅读", size: 44, symbolSize: 17) {
                        retry()
                    }
                case .done:
                    // Only a reading with a guide has two views to switch between.
                    if let reading = closeReading, reading.hasGuide {
                        Picker("阅读方式", selection: Binding(get: { showsOriginal }, set: { originalChoice = $0 })) {
                            Text("精读").tag(false)
                            Text("原文").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    if let reading = closeReading, !reading.hasGuide, task.status == .succeeded {
                        AmberGlassCircleButton(systemImage: "sparkles", accessibilityLabel: "生成精读", size: 44, symbolSize: 17) {
                            annotate(task)
                        }
                    }
                    // Custom HTML templates bring their own look, so styles only apply to built-in pages.
                    if customTemplateHTML(task) == nil {
                        glassCircleMenu(systemImage: "textformat", accessibilityLabel: "版式与样式") {
                            // Close readings and template articles have no magazine sections to reorder.
                            if closeReading == nil, templateArticle == nil {
                                Picker("版式", selection: $appearance.readerLayout) {
                                    ForEach(DeepReadReaderLayout.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                            Picker("样式", selection: $appearance.readerStyle) {
                                ForEach(DeepReadReaderStyle.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    glassCircleMenu(systemImage: "square.and.arrow.up", accessibilityLabel: "分享与导出") {
                        ShareLink(item: DeepReadTextExporter.text(from: shareMarkdown(task))) {
                            Label("分享文本", systemImage: "text.alignleft")
                        }
                        Button("导出为 Markdown", systemImage: "doc.plaintext") {
                            AmberHaptics.trigger(.lightImpact)
                            shareDeepRead(task, asPDF: false)
                        }
                        Button("导出为 PDF", systemImage: "doc.richtext") {
                            AmberHaptics.trigger(.lightImpact)
                            shareDeepRead(task, asPDF: true)
                        }
                    }
                case .generating:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.55),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea(edges: .top)
        }
    }

    // 与左侧 AmberGlassCircleButton 同一套玻璃圆形样式、图标字号与颜色；
    // 导出进度与失败走 App 级 IOSShareActivity 浮层，与对话导出一致。
    private func glassCircleMenu<Content: View>(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .buttonSizing(.flexible)
        .frame(width: 44, height: 44)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 正文已自带一级标题时不再重复加。
    private func shareMarkdown(_ task: IOSDeepReadTask) -> String {
        let body = task.resultMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.hasPrefix("# ") ? body : "# \(task.title)\n\n\(body)"
    }

    // 顶部浮动 toast(重试反馈),~1.7s 自动消失。
    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(AmberTheme.border.opacity(0.4), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                .padding(.top, 104)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // 杂志报头:kicker(全大写,字距)+ 衬线大标题 + 状态行(带状态点)+ 分隔线。三态都显示。
    @ViewBuilder
    private func masthead(_ task: IOSDeepReadTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker(task))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(AmberTheme.muted)

            Text(task.title)
                .font(.system(size: 31, weight: .medium, design: .serif))
                .foregroundStyle(AmberTheme.foreground)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            // 生成态不显示状态行 —— 骨架顶部的「正在生成阅读稿…排版中」已是唯一指示,
            // 避免与之重复。完成/失败态仍显示(已完成·时间 / 生成未完成·可重试)。
            if state(for: task) != .generating {
                statusLine(task)
                    .padding(.top, 14)
            }

            Rectangle()
                .fill(AmberTheme.borderSoft)
                .frame(height: 1)
                .padding(.top, state(for: task) == .generating ? 16 : 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        // 编辑器正文自带首段上间距(28)；分隔线直接落在正文起点，纯色正文与纹理页面的交界即这条线。
        .padding(.bottom, dividerMeetsEditorialBody(task) ? 0 : 18)
    }

    /// 完成态、未用自定义模板、且报头与正文之间没有横幅 → 编辑器正文紧接分隔线。
    /// 横幅自身无上边距，出现时仍由报头底部 18 撑开。
    private func dividerMeetsEditorialBody(_ task: IOSDeepReadTask) -> Bool {
        state(for: task) == .done
            && task.workspaceSyncFailed == nil
            && (task.missingSections ?? []).isEmpty
            && customTemplateHTML(task) == nil
    }

    @ViewBuilder
    private func statusLine(_ task: IOSDeepReadTask) -> some View {
        let st = state(for: task)
        HStack(spacing: 7) {
            Circle()
                .fill(statusTint(task.status))
                .frame(width: 7, height: 7)
                .opacity(st == .generating ? (statusPulse ? 0.3 : 1.0) : 0.9)
            Text(statusText(task))
                .font(.system(size: 12.5))
                .foregroundStyle(st == .failed ? AmberTheme.accentRed : AmberTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func content(_ task: IOSDeepReadTask) -> some View {
        switch state(for: task) {
        case .generating:
            IOSDeepReadNewsroomView(title: task.title, progressLabel: store.progressLabel(for: task.id))
        case .failed:
            failBanner(task)
            if !task.resultMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                articleContent(task)
            }
        case .done:
            articleContent(task)
        }
    }

    @ViewBuilder
    private func articleContent(_ task: IOSDeepReadTask) -> some View {
        if decodedJSON != .some(task.structuredJSON) {
            EmptyView()
        } else if let html = customTemplateHTML(task) {
            IOSDeepReadTemplateWebView(html: html)
                .frame(minHeight: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            // 完成:编辑器 HTML 阅读器(body-only,标题由上方 masthead 提供)。关掉 WebView
            // 内部滚动、按内容高度自适应,整篇随详情页一起滚动。
            // Close readings and template articles carry the original's images inside the page.
            IOSDeepReadEditorialWebView(html: articleHTML(task), contentHeight: $editorialHeight,
                                        allowsRemoteImages: closeReading != nil || templateArticle != nil)
                .frame(height: editorialHeight)
                .frame(maxWidth: .infinity)
                .id(task.id)
            if AmberThemeRuntime.shared.showsCanvasTexture(on: .app) {
                // 纹理/渐变画布上正文是纯色块：底边渐隐回页面背景，避免硬边。
                LinearGradient(
                    colors: [AmberTheme.background, AmberTheme.background.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
            } else {
                Color.clear.frame(height: 12)
            }
        }
    }

    @ViewBuilder
    private func workspaceSyncBanner(_ task: IOSDeepReadTask) -> some View {
        if state(for: task) == .done, let message = task.workspaceSyncFailed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentAmber)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已生成，但未保存到 Workspace")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                Button {
                    retryWorkspaceSync(task)
                } label: {
                    HStack(spacing: 6) {
                        if isRetryingWorkspaceSync {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(isRetryingWorkspaceSync ? "正在保存到 Workspace" : "仅重试保存到 Workspace")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRetryingWorkspaceSync)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AmberTheme.accentAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AmberTheme.accentAmber.opacity(0.28), lineWidth: 1) }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
    }

    // 部分段落未完成的琥珀横幅:LLM 生成完成后个别阶段没有可用内容(Android 每段 FAILED
    // 状态的 iOS 对等物),持久化在任务上,后台完成也能在详情页看到,并提供单段重试。
    @ViewBuilder
    private func partialSectionsBanner(_ task: IOSDeepReadTask) -> some View {
        let missing = task.missingSections ?? []
        if state(for: task) == .done, !missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentAmber)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("部分段落未完成")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: IOSAppLocalization.formatted(
                            closeReading != nil
                                ? "以下模块未能生成：%@。重新生成会重新读取原文与其他报道。"
                                : "以下模块未能生成：%@。重新生成只重跑这些缺失段落。",
                            defaultValue: closeReading != nil
                                ? "以下模块未能生成：%@。重新生成会重新读取原文与其他报道。"
                                : "以下模块未能生成：%@。重新生成只重跑这些缺失段落。",
                            arguments: [missing.map {
                                IOSAppLocalization.string($0, defaultValue: $0)
                            }.joined(separator: "、")]
                        ))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                Button {
                    retry()
                } label: {
                    Text("重新生成")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AmberTheme.accentAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AmberTheme.accentAmber.opacity(0.28), lineWidth: 1) }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
    }

    // 失败 inline 琥珀横幅(非浮卡、非 modal)。优先展示真实 failureMessage。
    @ViewBuilder
    private func failBanner(_ task: IOSDeepReadTask) -> some View {
        let detail = (store.persistenceError(for: task.id) ?? task.failureMessage)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (detail?.isEmpty == false)
            ? IOSDeepReadUserFacingText.sanitize(detail ?? "")
            : IOSAppLocalization.string(
                "生成未完成，部分内容可能不完整。点右上角重试。",
                defaultValue: "生成未完成，部分内容可能不完整。点右上角重试。"
            )
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(AmberTheme.accentAmber)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)   // 可复制服务商原话
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AmberTheme.accentAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AmberTheme.accentAmber.opacity(0.28), lineWidth: 1) }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    // 相关报道:杂志列表风(标题 + 媒体名),整条点击打开原文。与正文里原「扩展阅读」
    // 合并为这一个模块(数据统一用真实来源、可溯源),消除此前的重复与样式割裂。
    @ViewBuilder
    private func sourcesSection(_ task: IOSDeepReadTask) -> some View {
        let linkable = task.sources.filter {
            !($0.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        if !linkable.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("相关报道")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.bottom, 2)

                ForEach(linkable) { source in
                    DeepReadRelatedRow(source: source)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.7))
            await MainActor.run { withAnimation(.easeOut(duration: 0.25)) { toast = nil } }
        }
    }

    private func kicker(_ task: IOSDeepReadTask) -> String {
        if let closeReading {
            return showsOriginal ? "原文" : "精读 · " + DeepReadCloseReading.genreLabel(closeReading.genre)
        }
        if let templateArticle { return templateArticle.kind.name }
        let topicType = decodeStructured(task)?.topicType.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return topicType.isEmpty
            ? IOSAppLocalization.string("深度阅读", defaultValue: "深度阅读").uppercased()
            : topicType.uppercased()
    }

    private func statusText(_ task: IOSDeepReadTask) -> String {
        switch state(for: task) {
        case .generating:
            return IOSAppLocalization.string("正在生成阅读稿…", defaultValue: "正在生成阅读稿…")
        case .done:
            let date = Date(timeIntervalSince1970: Double(task.updatedAt) / 1000)
            let dateText = date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(IOSAppLanguagePreference.selected().resolvedLocale())
            )
            return IOSAppLocalization.formatted(
                "已完成 · %@",
                defaultValue: "已完成 · %@",
                arguments: [dateText]
            )
        case .failed:
            return IOSAppLocalization.string("生成未完成 · 可重试", defaultValue: "生成未完成 · 可重试")
        }
    }

    private func decodeStructured(_ task: IOSDeepReadTask) -> IOSDeepReadOutput? {
        task.structuredJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }
    }

    private func retry() {
        let partialCompletion = task?.status == .succeeded && !(task?.missingSections ?? []).isEmpty
        guard let task, task.status == .failed || task.status == .unsupported || partialCompletion else { return }
        guard let sharedSettings else {
            showToast(IOSAppLocalization.string("当前设置不可用，无法重试", defaultValue: "当前设置不可用，无法重试"))
            return
        }
        IOSDeepReadLauncher.retry(taskId: task.id, sharedSettings: sharedSettings) { message, isError in
            showToast(isError ? IOSDeepReadUserFacingText.sanitize(message) : message)
        }
    }

    private func annotate(_ task: IOSDeepReadTask) {
        guard let sharedSettings else {
            showToast(IOSAppLocalization.string("当前设置不可用，无法重试", defaultValue: "当前设置不可用，无法重试"))
            return
        }
        AmberHaptics.trigger(.lightImpact)
        originalChoice = nil
        IOSDeepReadLauncher.annotate(taskId: task.id, sharedSettings: sharedSettings) { message, isError in
            showToast(isError ? IOSDeepReadUserFacingText.sanitize(message) : message)
        }
    }

    private func retryWorkspaceSync(_ task: IOSDeepReadTask) {
        guard !isRetryingWorkspaceSync else { return }
        isRetryingWorkspaceSync = true
        defer { isRetryingWorkspaceSync = false }
        IOSDeepReadLauncher.retryWorkspaceSync(taskId: task.id, store: store) { message, _ in
            showToast(message)
        }
    }

    /// Builds the Android-style editorial HTML for a completed deep read: title
    /// headline + magazine-typeset Markdown body, with the diagonal hero figure when a
    /// source carries an image (e.g. a Brave thumbnail, stashed in source metadata).
    /// Hero image URL for the native cover above the masthead. Mirrors the source the
    /// editorial renderer used to use (task source `hero_image_url`, else the structured
    /// output's `heroImageUrl`), so the cover shows the same image — now above the title.
    private func coverImageURL(_ task: IOSDeepReadTask) -> String? {
        // Close readings and template articles place their own images inside the page.
        guard closeReading == nil, templateArticle == nil else { return nil }
        let metaHero = task.sources
            .compactMap { $0.metadata["hero_image_url"] }
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let structuredHero = task.structuredJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }?
            .heroImageUrl?.trimmingCharacters(in: .whitespaces)
        let hero = metaHero ?? structuredHero
        return (hero?.isEmpty == false) ? hero : nil
    }

    // 杂志封面图:宽度用 GeometryReader 锁定为容器宽(关键 —— 否则 scaledToFill 的图会按
    // 固有大尺寸把整列内容撑宽、导致标题/正文左右溢出屏幕被裁),从顶部满溢、底边斜切,
    // 标题在其下方 —— 头图在标题之上。
    @ViewBuilder
    private func coverImage(url: String) -> some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    AmberTheme.surface
                }
            }
            .frame(width: geo.size.width, height: 300)
            .clipped()
        }
        .frame(height: 300)
        .clipShape(CoverShape())
        .accessibilityHidden(true)
    }

    /// 封面底边斜切(复刻旧 WebView hero-cut 的斜切过渡:左低右高)。
    private struct CoverShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 26))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    private func shareDeepRead(_ task: IOSDeepReadTask, asPDF: Bool) {
        let activity = IOSShareActivity.shared
        guard activity.begin(asPDF ? "正在生成 PDF…" : "正在导出 Markdown…") else {
            activity.notify(IOSConversationExporter.busyMessage)
            return
        }
        Task { @MainActor in
            do {
                let url: URL
                if asPDF {
                    let data = try await IOSHTMLPDFRenderer.render(html: try pdfHTML(task))
                    url = try IOSShareFileWriter.write(data, fileName: task.title, pathExtension: "pdf")
                } else {
                    url = try IOSShareFileWriter.write(Data(shareMarkdown(task).utf8), fileName: task.title, pathExtension: "md")
                }
                let presented = await IOSShareSheet.present([url])
                activity.end(failure: presented ? nil : "当前无法弹出分享面板，请稍后重试。")
            } catch {
                activity.end(failure: error.localizedDescription)
            }
        }
    }

    /// PDF 与详情页同一版式：自定义模板走模板渲染（同样先过模板校验）；默认版式固定浅色并带标题，
    /// 因为详情页的原生标题/封面不会进入 PDF。
    private func pdfHTML(_ task: IOSDeepReadTask) throws -> String {
        let usesCustomTemplate = task.templateId.hasPrefix(IOSDeepReadTemplate.customPrefix)
            && templateStore.template(id: task.templateId) != nil
        guard usesCustomTemplate else {
            return IOSHTMLPDFRenderer.printFriendly(articleHTML(task, forPrint: true))
        }
        // 模板存在却渲染失败时明确报错，不静默退回默认版式（模板已删除时详情页与 PDF 都用默认版式）。
        guard let html = customTemplateHTML(task) else {
            throw IOSShareError("自定义模板渲染失败，无法按模板导出 PDF。")
        }
        let validation = IOSDeepReadTemplateValidator.validateHTML(html, requirePlaceholders: false)
        guard validation.ok else {
            throw IOSShareError("模板校验失败：\(validation.error ?? "未知错误")")
        }
        return IOSHTMLPDFRenderer.printFriendly(html)
    }

    /// Reader canvas colors: the app theme's palette, so the article follows the chosen background
    /// (paper or immersive) like the native masthead around it. PDF uses the light paper, because
    /// immersive canvases have no real light variant.
    private func readerPalette(forPrint: Bool) -> DeepReadCloseReadingRenderer.Palette {
        let dark = !forPrint && colorScheme == .dark
        let runtime = AmberThemeRuntime.shared
        let paper = runtime.paper
        let palette = forPrint
            ? (paper.isImmersive ? AmberTheme.paperLight : paper.lightPalette)
            : AmberTheme.resolvedCanvasPalette(paper: paper, design: runtime.design, dark: dark)
        func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
        return .init(accent: hex(runtime.accentHex), bg: hex(palette.background), fg: hex(palette.foreground),
                     surface: hex(palette.surface), muted: hex(palette.muted), border: hex(palette.border), dark: dark)
    }

    /// Untextured canvas: the page background is the same solid color, so a transparent article is seamless.
    private func transparentCanvas(forPrint: Bool) -> Bool {
        !forPrint && !AmberThemeRuntime.shared.showsCanvasTexture(on: .app)
    }

    private var readerFontScale: Double { Double(sharedSettings?.todayBoard.deepReadFontScale ?? 1) }
    private var readerFontMode: String { sharedSettings?.todayBoard.boardReadingFontMode.wireName ?? "serif" }

    /// Built-in article page: close reading, template article or the magazine editorial.
    private func articleHTML(_ task: IOSDeepReadTask, forPrint: Bool = false) -> String {
        guard closeReading != nil || templateArticle != nil else { return editorialHTML(task, forPrint: forPrint) }
        let palette = readerPalette(forPrint: forPrint)
        var css = appearance.readerStyle.css
        if forPrint {
            // The PDF loads no remote images (CSP), so they are hidden instead of leaving empty frames.
            css += "\nimg,figure{display:none!important;}"
        } else {
            // The native masthead carries the kicker and title on screen.
            css += "\n.headline>.kicker,.headline>h1{display:none;}"
            if transparentCanvas(forPrint: false) { css += "\nhtml,body{background:transparent;}" }
        }
        if let closeReading {
            return DeepReadCloseReadingRenderer.html(closeReading, palette: palette, fontMode: readerFontMode, styleCSS: css,
                                                     scale: readerFontScale, originalOnly: showsOriginal, expandNotes: forPrint)
        }
        return DeepReadTemplateArticleRenderer.html(templateArticle!, palette: palette, fontMode: readerFontMode,
                                                    styleCSS: css, scale: readerFontScale)
    }

    /// `forPrint` 用于导出 PDF：固定浅色、带标题（详情页的原生标题/封面不会进入 PDF）。
    private func editorialHTML(_ task: IOSDeepReadTask, forPrint: Bool = false) -> String {
        // Structured output (when the LLM produced it) drives the rich cards; else the
        // renderer falls back to the flat-markdown body.
        let structured: IOSDeepReadOutput? = task.structuredJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }
        let kicker = (structured?.topicType.isEmpty == false)
            ? structured!.topicType.uppercased()
            : IOSAppLocalization.string("深度阅读", defaultValue: "深度阅读").uppercased()
        let palette = readerPalette(forPrint: forPrint)
        let layout = appearance.readerLayout
        let html = IOSDeepReadEditorialRenderer.renderHTML(
            IOSDeepReadEditorialRenderer.Input(
                title: task.title,
                markdown: task.resultMarkdown,
                kicker: kicker,
                // Hero is now rendered NATIVELY above the masthead (cover-first, title below) —
                // see `coverImageURL`/`coverImage` in the detail view. Suppress the WebView's
                // top hero block so it isn't duplicated below the title.
                heroImageURL: nil,
                heroCaption: nil,
                sourceLabel: nil,
                dark: palette.dark,
                structured: structured,
                sectionOrder: layout.order,
                showHeadline: forPrint,
                accentHex: palette.accent,
                fontMode: readerFontMode,
                bgHex: palette.bg,
                fgHex: palette.fg,
                surfaceHex: palette.surface,
                mutedHex: palette.muted,
                borderHex: palette.border,
                // 无纹理画布：页面背景就是同一纯色，正文透明即无缝；有纹理时保持纯色以保可读。
                transparentCanvas: transparentCanvas(forPrint: forPrint)
            )
        )
        // 版式与阅读样式只叠加一层 CSS；字号按设置缩放整篇正文。
        return html.replacingOccurrences(
            of: "</head>",
            with: "<style>\(layout.css)\n\(appearance.readerStyle.css)\nbody{zoom:\(readerFontScale)}</style></head>"
        )
    }

    private func customTemplateHTML(_ task: IOSDeepReadTask) -> String? {
        // Close readings and template articles have their own structure and always use the built-in page.
        guard closeReading == nil, templateArticle == nil,
              task.templateId.hasPrefix(IOSDeepReadTemplate.customPrefix),
              let template = templateStore.template(id: task.templateId) else {
            return nil
        }
        let board = sharedSettings?.todayBoard
        return try? IOSDeepReadHTMLTemplateRenderer.render(
            task: task,
            template: template,
            fontScale: board?.deepReadFontScale ?? 1.0,
            fontModeWireName: board?.boardReadingFontMode.wireName ?? "serif"
        )
    }

    private func statusTint(_ status: IOSDeepReadTaskStatus) -> Color {
        switch status {
        case .queued, .running: AmberTheme.accentAmber
        case .succeeded: AmberTheme.accentGreen
        case .failed: AmberTheme.accentRed
        case .unsupported: AmberTheme.muted2
        }
    }
}
