import Foundation
import SwiftUI
import WebKit

enum WebMountSitePresentationMode: String, Hashable {
    case browse
    case watch
}

struct WebMountSiteRoute: Hashable, Identifiable {
    let siteId: String
    let name: String
    let host: String
    let sessionId: String?
    let mode: WebMountSitePresentationMode

    var id: String { "\(siteId):\(sessionId ?? "current"):\(mode.rawValue)" }

    init(
        siteId: String,
        name: String,
        host: String,
        sessionId: String? = nil
    ) {
        self.siteId = siteId
        self.name = name
        self.host = host
        self.sessionId = sessionId?.nilIfBlank
        self.mode = .browse
    }

    init(
        site: IOSWebMountSite,
        sessionId: String? = nil
    ) {
        self.siteId = site.id
        self.name = site.displayName
        self.host = site.homepageHost
        self.sessionId = sessionId?.nilIfBlank
        self.mode = .browse
    }

    @MainActor
    init?(watching record: IOSWebMountSessionRecord, registry: IOSWebMountRegistry) {
        guard record.backend == .local,
              let sessionId = record.id.nilIfBlank else {
            return nil
        }
        if let siteId = record.siteId?.nilIfBlank,
           let site = registry.site(id: siteId) {
            self.siteId = site.id
            self.name = site.displayName
            self.host = site.homepageHost
        } else {
            guard let components = URLComponents(string: record.redactedURL),
                  let host = components.host?.nilIfBlank else {
                return nil
            }
            self.siteId = "unlisted:\(sessionId)"
            self.name = record.title.nilIfBlank ?? host
            self.host = host
        }
        self.sessionId = sessionId
        self.mode = .watch
    }
}

enum IOSDeepReadWebMountAdapter {
    @MainActor
    static func currentPageSource(
        controller: IOSWebMountController = .shared,
        maxChars: Int = 20_000
    ) async -> Result<IOSDeepReadSource, IOSDeepReadSourceNormalizationError> {
        let snapshot = controller.runtime.snapshot
        guard snapshot.status == .ready else {
            let reason = snapshot.error.map(IOSWebMountRedactor.redactedText)?.nilIfBlank
                ?? "站点当前没有已加载完成的页面；请先打开站点并停留在要深读的页面。"
            return .failure(.unsupported(reason))
        }
        do {
            let extracted = try await controller.runtime.extract(mode: "readable", maxChars: maxChars, maxLinks: 20)
            let rawResult = extracted["text"] as? String
                ?? (extracted["result"] as? [String: Any])?["text"] as? String
                ?? ""
            let result = IOSWebMountRedactor.redactedText(rawResult)
            let rawTitle = extracted["title"] as? String
                ?? (extracted["result"] as? [String: Any])?["title"] as? String
                ?? snapshot.title
                ?? "站点页面"
            let title = IOSWebMountRedactor.redactedText(rawTitle)
            let rawURL = extracted["url"] as? String
                ?? (extracted["result"] as? [String: Any])?["url"] as? String
                ?? snapshot.currentURL
            let url = IOSWebMountRedactor.redactedURL(rawURL)
            let source = try IOSDeepReadSourceNormalizer.webMountSource(title: title, url: url, text: result)
            return .success(source)
        } catch let error as IOSDeepReadSourceNormalizationError {
            return .failure(error)
        } catch {
            return .failure(.unsupported("站点页面正文读取失败：\(IOSDeepReadUserFacingText.fromError(error))"))
        }
    }
}

struct IOSWebMountContentHandoff: Equatable, Identifiable {
    let id: String
    let siteId: String
    let siteName: String
    let title: String
    let sourceURL: String
    let text: String
    let linkCount: Int
    let createdAtMillis: Int64

    var chatPrompt: String {
        """
        请基于以下站点网页内容继续帮我处理。

        来源：\(siteName)
        标题：\(title.nilIfBlank ?? siteName)
        URL：\(sourceURL)
        链接数：\(linkCount)

        正文：
        \(String(text.prefix(12_000)))
        """
    }

    var boardSignal: IOSRawBoardSignal {
        IOSRawBoardSignal(
            sourceType: IOSBoardSignalSourceType.webmount,
            sourceRef: "webmount:\(siteId):\(sourceURL)",
            title: title.nilIfBlank ?? siteName,
            content: String(text.prefix(4_000)),
            signalTime: createdAtMillis,
            metadataJson: IOSWebMountController.json([
                "site_id": siteId,
                "site_name": siteName,
                "source_url": sourceURL,
                "link_count": linkCount,
                "redacted": true
            ])
        )
    }

    static func from(
        site: IOSWebMountSite,
        snapshot: IOSWebMountRuntimeSnapshot,
        extraction: [String: Any]
    ) -> IOSWebMountContentHandoff? {
        let rawText = (extraction["text"] as? String)?.nilIfBlank
        guard let rawText else { return nil }
        let redactedText = IOSWebMountRedactor.redactedText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redactedText.isEmpty else { return nil }
        let sourceURL = IOSWebMountRedactor.redactedURL(extraction["url"] as? String)
            ?? snapshot.currentURL
            ?? IOSWebMountRedactor.redactedURL(site.homepageURL)
            ?? site.homepageHost
        let links = extraction["links"] as? [[String: Any]] ?? []
        return IOSWebMountContentHandoff(
            id: UUID().uuidString,
            siteId: site.id,
            siteName: site.displayName,
            title: IOSWebMountRedactor.redactedText((extraction["title"] as? String)?.nilIfBlank ?? snapshot.title ?? site.displayName),
            sourceURL: sourceURL,
            text: redactedText,
            linkCount: links.count,
            createdAtMillis: IOSWebMountClock.nowMillis()
        )
    }
}

@MainActor
final class IOSWebMountContentHandoffStore {
    static let shared = IOSWebMountContentHandoffStore()

    private var pendingChatHandoff: IOSWebMountContentHandoff?
    private var pendingDeepReadHandoff: IOSWebMountContentHandoff?

    private init() {}

    func prepareChat(_ handoff: IOSWebMountContentHandoff) {
        pendingChatHandoff = handoff
    }

    func consumeChatHandoff() -> IOSWebMountContentHandoff? {
        defer { pendingChatHandoff = nil }
        return pendingChatHandoff
    }

    func prepareDeepRead(_ handoff: IOSWebMountContentHandoff) {
        pendingDeepReadHandoff = handoff
    }

    func consumeDeepReadHandoff() -> IOSWebMountContentHandoff? {
        defer { pendingDeepReadHandoff = nil }
        return pendingDeepReadHandoff
    }
}

@MainActor
@Observable
final class IOSWebMountActivityStore {
    static let shared = IOSWebMountActivityStore()

    var recentExtractionTitle = "—"
    var recentExtractionDetail = "暂无"
    var recentExtractionAtMillis: Int64 = 0

    private init() {}

    func recordExtraction(siteName: String, title: String?, characterCount: Int, linkCount: Int) {
        recentExtractionTitle = title?.nilIfBlank ?? siteName
        recentExtractionDetail = "\(siteName) · \(characterCount) 字符 · \(linkCount) 链接"
        recentExtractionAtMillis = IOSWebMountClock.nowMillis()
    }
}

private enum WebMountResultTab: String, CaseIterable, Identifiable {
    case text
    case links
    case interactive
    case visual
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "正文"
        case .links: "链接"
        case .interactive: "交互"
        case .visual: "视觉"
        case .debug: "调试"
        }
    }
}

private enum WebMountActionLayout {
    static let minimumButtonSpacing: CGFloat = 12
    static let glassInteractionSpacing: CGFloat = 8
}

@MainActor
struct AgentBrowserTaskCard: View {
    let record: IOSWebMountSessionRecord
    let onCollapse: (() -> Void)?
    let onOpen: () -> Void

    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        record: IOSWebMountSessionRecord,
        onCollapse: (() -> Void)? = nil,
        onOpen: @escaping () -> Void
    ) {
        self.record = record
        self.onCollapse = onCollapse
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                taskIdentity
                Spacer(minLength: 4)
                collapseButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            Divider()
                .overlay(AmberTheme.borderSoft)
                .padding(.leading, 54)

            HStack(spacing: 8) {
                statusBadge
                backendLabel
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text(openLabel)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("\(openLabel)，\(siteTitle)，\(status.label)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
        .simultaneousGesture(collapseGesture)
        .offset(y: min(12, dragTranslation * 0.24))
    }

    @ViewBuilder
    private var collapseButton: some View {
        if onCollapse != nil {
            Button(action: collapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起浏览器任务")
            .accessibilityHint("向下拖动或轻点收起")
        }
    }

    private var collapseGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let projected = max(value.translation.height, value.predictedEndTranslation.height)
                guard projected > 44, abs(value.translation.height) > abs(value.translation.width) else { return }
                collapse()
            }
    }

    private func collapse() {
        guard let onCollapse else { return }
        withAnimation(collapseAnimation) {
            onCollapse()
        }
    }

    private var collapseAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var taskIdentity: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(width: 34, height: 34)
                .background(
                    AmberTheme.surface2,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(siteTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(pageSummary)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: status.image)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 24, height: 24)
                .background(
                    status.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Circle()
                .fill(status.tint)
                .frame(width: 5, height: 5)
            Text(status.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var backendLabel: some View {
        Label(backendTitle, systemImage: record.backend == .local ? "iphone" : "desktopcomputer")
            .font(.caption2)
            .foregroundStyle(AmberTheme.muted)
    }

    private var backendTitle: String {
        record.backend == .local ? "本机浏览器" : record.backend.title
    }

    private var siteTitle: String {
        displayInfo.siteTitle
    }

    private var pageSummary: String {
        displayInfo.pageSummary
    }

    private var openLabel: String {
        record.backend == .local ? "观看页面" : "查看状态"
    }

    private var status: (label: String, image: String, tint: Color) {
        displayInfo.status
    }

    private var displayInfo: AgentBrowserTaskDisplayInfo {
        AgentBrowserTaskDisplayInfo(record: record)
    }
}

@MainActor
struct AgentBrowserTaskCompactBar: View {
    let record: IOSWebMountSessionRecord
    let runSummary: String?
    let onExpand: () -> Void

    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: displayInfo.status.image)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(displayInfo.status.tint)
                .frame(width: 22, height: 22)
                .background(displayInfo.status.tint.opacity(0.12), in: Circle())

            Text(summary)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AmberTheme.accent)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .agentBrowserSummaryGlass(cornerRadius: 18)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .offset(y: max(-8, dragTranslation * 0.18))
        .onTapGesture(perform: expand)
        .simultaneousGesture(expandGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(summary)
        .accessibilityHint("轻点或向上滑动展开浏览器任务")
        .accessibilityAction(named: "展开浏览器任务", expand)
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = min(0, value.translation.height)
            }
            .onEnded { value in
                let projected = min(value.translation.height, value.predictedEndTranslation.height)
                guard projected < -36, abs(value.translation.height) > abs(value.translation.width) else { return }
                expand()
            }
    }

    private func expand() {
        withAnimation(animation) {
            onExpand()
        }
    }

    private var summary: String {
        runSummary?.nilIfBlank ?? displayInfo.fallbackSummary
    }

    private var displayInfo: AgentBrowserTaskDisplayInfo {
        AgentBrowserTaskDisplayInfo(record: record)
    }

    private var animation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }
}

private extension View {
    @ViewBuilder
    func agentBrowserSummaryGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            background(AmberTheme.accent.opacity(0.08), in: shape)
                .glassEffect(
                    .regular.tint(AmberTheme.accent.opacity(0.28)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.fill(AmberTheme.accent.opacity(0.10))
                }
                .overlay {
                    shape.stroke(AmberTheme.accent.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: AmberTheme.accent.opacity(0.12), radius: 10, y: 3)
        }
    }
}

@MainActor
private struct AgentBrowserTaskDisplayInfo {
    let record: IOSWebMountSessionRecord

    var siteTitle: String {
        record.siteName?.nilIfBlank ?? record.title.nilIfBlank ?? "未命名页面"
    }

    var pageSummary: String {
        guard let rawURL = record.redactedURL.nilIfBlank,
              let components = URLComponents(string: rawURL),
              let host = components.host?.nilIfBlank else {
            return record.redactedURL.nilIfBlank ?? "尚未打开页面"
        }
        let path = components.percentEncodedPath
        return path.isEmpty || path == "/" ? host : host + path
    }

    var fallbackSummary: String {
        [status.label, siteTitle, pageSummary]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { parts, value in
                if parts.last != value { parts.append(value) }
            }
            .joined(separator: " · ")
    }

    var status: (label: String, image: String, tint: Color) {
        if record.needsReopen {
            return ("需要重新打开", "arrow.clockwise", AmberTheme.accentAmber)
        }
        switch record.controlOwner {
        case .user:
            return ("需要你处理", "person.crop.circle.badge.exclamationmark", AmberTheme.accentAmber)
        case .agent:
            return ("Agent 浏览中", "cursorarrow.click.2", AmberTheme.statusAmber)
        case .none:
            break
        }
        switch record.status {
        case IOSWebMountRuntimeStatus.loading.rawValue:
            return ("正在加载", "arrow.triangle.2.circlepath", AmberTheme.accentAmber)
        case IOSWebMountRuntimeStatus.failed.rawValue:
            return ("浏览失败", "exclamationmark.triangle", AmberTheme.accentRed)
        default:
            return ("等待 Agent", "clock", AmberTheme.muted)
        }
    }
}

@MainActor
struct WebMountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    @State private var controller: IOSWebMountController
    @State private var showAddSite = false
    @State private var addName = ""
    @State private var addURL = ""
    @State private var addNeedsLogin = true
    @State private var addCookieName = ""
    @State private var addSiteError: String?
    @State private var banner: String?
    @State private var showDesktopBackends = false
    @State private var focusedRemoteSessionId: String?

    private var registry: IOSWebMountRegistry { controller.registry }
    private var settings: IOSWebMountSettings { controller.settings }

    init(controller: IOSWebMountController = .shared) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ZStack {
            AmberThemePageBackground(surface: .app)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        if let banner {
                            WebMountBanner(text: banner)
                                .padding(.top, 4)
                        }
                        stationSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAddSite) {
            addSiteSheet
        }
        .sheet(isPresented: $showDesktopBackends, onDismiss: {
            focusedRemoteSessionId = nil
        }) {
            WebMountDesktopBackendsView(
                controller: controller,
                focusedSessionId: focusedRemoteSessionId
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text(IOSAppLocalization.string("WebMount", defaultValue: "WebMount"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(registry.sites.count) 个站点")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
            }

            Spacer()

            Button {
                addSiteError = nil
                showAddSite = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .amberGlass(cornerRadius: 22)
            .accessibilityLabel("添加 WebMount 站点")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var stationSection: some View {
        VStack(spacing: 0) {
            desktopBackendSection
            agentBrowserTaskSection
            AmberSectionLabel(text: "站点")
            AmberFormGroup {
                if registry.sites.isEmpty {
                    Text("还没有 WebMount 站点。添加一个 http(s) 网站，或恢复内置站点。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(registry.sites.enumerated()), id: \.element.id) { index, site in
                        WebMountStationRow(
                            site: site,
                            onOpen: {
                                router.navigate(to: .webMountSite(site: WebMountSiteRoute(
                                    site: site,
                                    sessionId: controller.sessionStore.currentSessionId
                                )))
                            },
                            onToggle: { enabled in
                                registry.setEnabled(id: site.id, enabled: enabled)
                            },
                            onDelete: {
                                delete(site)
                            }
                        )
                        if index < registry.sites.count - 1 {
                            WebMountDivider()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    let restored = registry.restoreMissingSeeds()
                    settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
                    banner = restored == 0 ? "内置站点已是最新。" : "已恢复 \(restored) 个内置站点。"
                } label: {
                    Label("恢复内置站点", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private var desktopBackendSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "浏览器")
            AmberFormGroup {
                AmberFormRow(
                    systemImage: "macwindow.on.rectangle",
                    iconColor: AmberTheme.accent,
                    title: "浏览器与会话",
                    subtitle: "管理本地与桌面浏览器",
                    trailing: "管理",
                    showsChevron: true
                ) {
                    focusedRemoteSessionId = nil
                    showDesktopBackends = true
                }
            }
        }
    }

    private var agentBrowserSessions: [IOSWebMountSessionRecord] {
        controller.sessionStore.records
            .filter { record in
                let isActive = record.ownerRunId?.nilIfBlank != nil
                let isUserHeld = record.controlOwner == .user && record.ownerConversationId?.nilIfBlank != nil
                let isRecoverable = record.needsReopen && record.ownerConversationId?.nilIfBlank != nil
                guard isActive || isUserHeld || isRecoverable else { return false }
                return record.backend != .local || WebMountSiteRoute(watching: record, registry: registry) != nil
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityMillis != rhs.lastActivityMillis {
                    return lhs.lastActivityMillis > rhs.lastActivityMillis
                }
                return lhs.id < rhs.id
            }
    }

    private var agentBrowserTaskSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Agent 浏览器任务")
            if agentBrowserSessions.isEmpty {
                AmberFormGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无 Agent 浏览任务")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("Agent 开始浏览网页后，可在这里观看或接管页面。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(agentBrowserSessions) { record in
                        AgentBrowserTaskCard(record: record) {
                            openAgentBrowserSession(record.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func openAgentBrowserSession(_ sessionId: String) {
        guard let record = controller.sessionStore.record(sessionId: sessionId) else {
            banner = "此站点会话不存在或已过期。"
            return
        }
        if record.backend == .local {
            guard let route = WebMountSiteRoute(watching: record, registry: registry) else {
                banner = "此站点会话未绑定可用站点，无法观看。"
                return
            }
            router.navigate(to: .webMountSite(site: route))
        } else {
            focusedRemoteSessionId = record.id
            Task { @MainActor in
                showDesktopBackends = true
            }
        }
    }

    private var addSiteSheet: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        AmberFormGroup {
                            WebMountTextFieldRow(title: "名称", text: $addName, placeholder: "示例")
                            WebMountDivider()
                            WebMountTextFieldRow(title: "网址", text: $addURL, placeholder: "https://example.com")
                            WebMountDivider()
                            WebMountToggleRow(
                                title: "需要登录",
                                subtitle: "保存登录提示，不会自动打开登录流程。",
                                systemImage: "person.badge.key",
                                tint: AmberTheme.accent,
                                isOn: $addNeedsLogin
                            )
                            if addNeedsLogin {
                                WebMountDivider()
                                WebMountTextFieldRow(title: "Cookie 提示", text: $addCookieName, placeholder: "可选")
                            }
                        }

                        if let addSiteError {
                            WebMountBanner(text: addSiteError)
                        }

                        Text("自定义站点会保存在本机，Cookie 内容不会在页面中显示。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    .padding(.top, 16)
                }
            }
            .navigationTitle("添加站点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddSite = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { addSite() }
                }
            }
        }
    }

    private func addSite() {
        do {
            let site = try registry.addCustomSite(
                displayName: addName,
                homepageURL: addURL,
                needsLogin: addNeedsLogin,
                loginCookieName: addCookieName
            )
            settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
            addName = ""
            addURL = ""
            addCookieName = ""
            addNeedsLogin = true
            addSiteError = nil
            showAddSite = false
            banner = "已添加 \(site.displayName)。"
        } catch {
            addSiteError = "添加失败。请填写名称，并使用 http(s) 网址。"
        }
    }

    private func delete(_ site: IOSWebMountSite) {
        if registry.remove(id: site.id) {
            settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
            banner = "已移除 \(site.displayName)。"
        }
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
struct WebMountSiteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    let site: WebMountSiteRoute

    @State private var controller: IOSWebMountController
    @ObservedObject private var runtime: IOSWebMountWKRuntime
    @State private var cookieSummary: IOSWebMountCookieSummary?
    @State private var bridgeState = ""
    @State private var extractText = ""
    @State private var linksText = ""
    @State private var interactiveText = ""
    @State private var visualSnapshotText = ""
    @State private var debugJSONText = ""
    @State private var selectedResultTab: WebMountResultTab = .text
    @State private var getSelector = "body"
    @State private var getText = ""
    @State private var openURLText = ""
    @State private var contentHandoff: IOSWebMountContentHandoff?
    @State private var banner: String?
    @State private var isLoading = false
    @State private var observationRequestID: UUID?
    @State private var showInspector = false
    @AppStorage("app.amber.ios.highRiskAutoApprove") private var highRiskAutoApprove = false
    private let hasBoundSession: Bool

    private var registry: IOSWebMountRegistry { controller.registry }
    private var isUnlistedWatchSession: Bool {
        site.mode == .watch && registry.site(id: site.siteId) == nil
    }
    private var resolvedSite: IOSWebMountSite {
        registry.site(id: site.siteId) ?? IOSWebMountSite(
            id: site.siteId,
            displayName: site.name,
            homepageURL: "https://\(site.host)",
            authKind: .anonymous,
            loginCookieName: nil,
            nativeAdapterId: nil,
            iconKey: nil,
            oauthProviderId: nil,
            allowedHosts: [site.host],
            enabled: false,
            addedAtMillis: IOSWebMountClock.nowMillis()
        )
    }

    init(site: WebMountSiteRoute, controller: IOSWebMountController = .shared) {
        self.site = site
        _controller = State(initialValue: controller)
        let boundRuntime: IOSWebMountRuntimeServicing?
        if site.mode == .watch {
            boundRuntime = site.sessionId?.nilIfBlank.flatMap {
                controller.sessionStore.runtimeIfPresent(sessionId: $0)
            }
        } else {
            boundRuntime = controller.sessionStore.runtimeIfPresent(sessionId: site.sessionId)
        }
        if let webRuntime = boundRuntime as? IOSWebMountWKRuntime {
            _runtime = ObservedObject(wrappedValue: webRuntime)
            hasBoundSession = true
        } else {
            _runtime = ObservedObject(wrappedValue: IOSWebMountWKRuntime(sessionId: site.sessionId))
            hasBoundSession = false
        }
    }

    private var isWatchMode: Bool {
        site.mode == .watch
    }

    private var sessionRecord: IOSWebMountSessionRecord? {
        guard hasBoundSession else { return nil }
        let sessionId = isWatchMode ? site.sessionId : runtime.snapshot.sessionId
        guard let sessionId = sessionId?.nilIfBlank else { return nil }
        return controller.sessionStore.record(sessionId: sessionId)
    }

    private var isAgentControlActive: Bool {
        sessionRecord?.controlOwner == .agent
    }

    private var canUserMutate: Bool {
        hasBoundSession && sessionRecord?.controlOwner == .user
    }

    private var hasViewablePage: Bool {
        guard hasBoundSession, let sessionRecord else { return false }
        return !sessionRecord.needsReopen
    }

    private var canReadPage: Bool {
        hasViewablePage && runtime.snapshot.status == .ready
    }

    private var displayedBanner: String? {
        if isWatchMode {
            guard hasBoundSession, let sessionRecord else {
                return "此站点会话不存在或已过期，请返回任务列表。"
            }
            if let banner {
                return banner
            }
            if sessionRecord.needsReopen {
                return "此站点会话需要重新打开；Amber 不会自动恢复旧页面或动作。"
            }
            if runtime.snapshot.status == .idle {
                return "此 session 尚未打开页面；观看不会自动导航。"
            }
            if runtime.snapshot.status == .failed,
               let error = runtime.snapshot.error?.nilIfBlank {
                return "页面加载失败：\(IOSWebMountRedactor.redactedText(error))"
            }
        }
        return banner
    }

    var body: some View {
        ZStack {
            AmberThemePageBackground(surface: .app)

            VStack(spacing: 0) {
                header
                workspaceBrowserBar

                if let banner = displayedBanner {
                    WebMountBanner(text: banner)
                }

                webViewSection
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if openURLText.isEmpty {
                openURLText = runtime.snapshot.currentURL
                    ?? runtime.snapshot.requestedURL
                    ?? resolvedSite.homepageURL
            }
            guard hasBoundSession, sessionRecord != nil else {
                await refreshCookieSummary()
                return
            }
            if isWatchMode {
                if let sessionId = site.sessionId?.nilIfBlank {
                    controller.sessionStore.touch(sessionId: sessionId, makeCurrent: false)
                }
                await refreshCookieSummary()
                return
            }
            controller.sessionStore.touch(sessionId: runtime.snapshot.sessionId, makeCurrent: true)
            if sessionRecord?.controlOwner == IOSWebMountControlOwner.none {
                _ = try? controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
            }
            await refreshCookieSummary()
            if runtime.snapshot.status == .idle && !isAgentControlActive {
                await openSite()
            }
        }
        .sheet(isPresented: $showInspector) {
            inspectorSheet
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(resolvedSite.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(resolvedSite.homepageHost)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 88)

            HStack(spacing: 0) {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回站点", size: 44, symbolSize: 20) {
                    dismiss()
                }

                Spacer()

                AmberGlassCircleButton(systemImage: "arrow.clockwise", accessibilityLabel: "重新加载", size: 44, symbolSize: 17) {
                    Task { await openSite() }
                }
                .disabled(isLoading || !canUserMutate)
                .opacity(isLoading || !canUserMutate ? 0.45 : 1)

                Button {
                    showInspector = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开页面检查器")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var workspaceBrowserBar: some View {
        HStack(spacing: 4) {
            workspaceBrowserButton(
                systemImage: "chevron.left",
                accessibilityLabel: "网页后退",
                isEnabled: runtime.snapshot.canGoBack && canUserMutate
            ) {
                Task { _ = await runtime.back() }
            }

            workspaceBrowserButton(
                systemImage: "chevron.right",
                accessibilityLabel: "网页前进",
                isEnabled: runtime.snapshot.canGoForward && canUserMutate
            ) {
                Task { _ = await runtime.forward() }
            }

            TextField("输入网址", text: $openURLText)
                .font(.footnote)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(!canUserMutate)

            workspaceBrowserButton(
                systemImage: "arrow.right",
                accessibilityLabel: "打开网址",
                isEnabled: !isLoading && canUserMutate
            ) {
                Task { await openTypedURL() }
            }

            workspaceControlButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AmberTheme.surface)
        .overlay(alignment: .bottom) {
            Divider().overlay(AmberTheme.borderSoft)
        }
    }

    private func workspaceBrowserButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? AmberTheme.foreground2 : AmberTheme.muted2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var workspaceControlButton: some View {
        Button {
            if sessionRecord?.controlOwner == .user {
                handBackToAgent()
            } else {
                takeUserControl()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: controlOwnerImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(controlOwnerTint)
                    .frame(width: 22, height: 22)
                    .background(
                        controlOwnerTint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    Text(workspaceControlOwnerLabel)
                        .font(.caption2.weight(.bold))
                    Text(workspaceControlActionLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(controlOwnerTint)
                }
                .lineLimit(1)
            }
            .foregroundStyle(AmberTheme.foreground2)
            .padding(.horizontal, 8)
            .frame(minWidth: 86, minHeight: 44)
            .background(
                controlOwnerTint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(controlOwnerTint.opacity(0.30), lineWidth: 0.7)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(sessionRecord == nil)
        .opacity(sessionRecord == nil ? 0.45 : 1)
        .layoutPriority(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IOSAppLocalization.string(workspaceControlAccessibilityLabel))
        .accessibilityValue(controlOwnerBadgeText)
        .accessibilityHint("切换页面控制权")
    }

    private var inspectorSheet: some View {
        NavigationStack {
            ZStack {
                AmberThemePageBackground(surface: .app)

                ScrollView {
                    VStack(spacing: 0) {
                        runtimeSection
                        bridgeSection
                        cookieSection
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("页面检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showInspector = false }
                }
            }
        }
        .presentationDetents([.height(320), .height(620)])
        .presentationDragIndicator(.visible)
    }

    private var runtimeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "网页状态")
            AmberFormGroup {
                WebMountInfoRow(
                    title: statusText,
                    subtitle: statusSubtitle,
                    systemImage: statusImage,
                    tint: statusTint,
                    trailing: runtime.snapshot.title?.nilIfBlank ?? "\(Int(runtime.snapshot.estimatedProgress * 100))%"
                )
                WebMountDivider()
                browserChromeRow
                WebMountDivider()
                controlRow
                WebMountDivider()
                AmberGlassGroup(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            openURLField
                            openURLButton
                        }
                        VStack(alignment: .trailing, spacing: 8) {
                            openURLField
                            openURLButton
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                WebMountDivider()
                AmberGlassGroup(spacing: WebMountActionLayout.glassInteractionSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WebMountActionLayout.minimumButtonSpacing) {
                            navigationButtons
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: WebMountActionLayout.minimumButtonSpacing) {
                            navigationButtons
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private var openURLField: some View {
        TextField("https://example.com/path", text: $openURLText)
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(maxWidth: .infinity)
            .disabled(!canUserMutate)
    }

    private var openURLButton: some View {
        Button("打开") { Task { await openTypedURL() } }
            .buttonStyle(.glassProminent)
            .frame(minHeight: 44)
            .disabled(isLoading || !canUserMutate)
    }

    @ViewBuilder
    private var navigationButtons: some View {
        Button {
            Task {
                guard canUserMutate else {
                    banner = "Agent 正在控制此页面，请先接管。"
                    return
                }
                _ = await runtime.back()
            }
        } label: {
            Label("后退", systemImage: "chevron.left")
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
        .disabled(!runtime.snapshot.canGoBack || !canUserMutate)

        Button {
            Task {
                guard canUserMutate else {
                    banner = "Agent 正在控制此页面，请先接管。"
                    return
                }
                _ = await runtime.forward()
            }
        } label: {
            Label("前进", systemImage: "chevron.right")
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
        .disabled(!runtime.snapshot.canGoForward || !canUserMutate)
    }

    @ViewBuilder
    private var bridgeActionButtons: some View {
        Button("状态") { Task { await readState() } }
            .buttonStyle(.glass)
            .frame(minHeight: 44)
            .disabled(!canReadPage)
        Button("提取正文") { Task { await extractReadable() } }
            .buttonStyle(.glass)
            .frame(minHeight: 44)
            .disabled(!canReadPage)
        Button("观察") { Task { await self.observePage() } }
            .buttonStyle(.glass)
            .frame(minHeight: 44)
            .disabled(!canReadPage || observationRequestID != nil)
        Button("视觉快照") { Task { await visualSnapshot() } }
            .buttonStyle(.glass)
            .frame(minHeight: 44)
            .disabled(!canReadPage)
    }

    private var browserChromeRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if isWatchMode {
                    WebMountBadge(text: "观看模式", systemImage: "eye", tint: AmberTheme.accentCyan)
                }
                WebMountBadge(text: resolvedSite.homepageHost, systemImage: "network", tint: AmberTheme.accentCyan)
                WebMountBadge(text: loginBadgeText, systemImage: "person.crop.circle", tint: loginBadgeTint)
                if isWatchMode, registry.site(id: site.siteId) == nil {
                    WebMountBadge(text: "高风险模式", systemImage: "exclamationmark.shield", tint: AmberTheme.accentAmber)
                } else {
                    WebMountBadge(
                        text: resolvedSite.enabled ? "Agent 已允许" : "Agent 未允许",
                        systemImage: resolvedSite.enabled ? "checkmark.shield" : "xmark.shield",
                        tint: resolvedSite.enabled ? AmberTheme.accentGreen : AmberTheme.accentRed
                    )
                }
                WebMountBadge(text: runtime.snapshot.sessionId, systemImage: "rectangle.stack", tint: AmberTheme.accentIndigo)
                WebMountBadge(text: controlOwnerBadgeText, systemImage: controlOwnerImage, tint: controlOwnerTint)
                if let sessionRecord, sessionRecord.persistentOptIn {
                    WebMountBadge(text: "持久会话", systemImage: "pin", tint: AmberTheme.accentAmber)
                }
                if let sessionRecord, sessionRecord.needsReopen {
                    WebMountBadge(text: "需要重新打开", systemImage: "arrow.clockwise", tint: AmberTheme.accentRed)
                }
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var webViewSection: some View {
        Group {
            if hasViewablePage {
                WebMountRuntimeWebView(runtime: runtime, isInteractive: canUserMutate)
                    .accessibilityHint(isWatchMode && !canUserMutate ? "观看模式，仅可查看；接管后可操作。" : "")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: sessionRecord?.needsReopen == true ? "arrow.clockwise" : "rectangle.slash")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AmberTheme.muted2)
                    Text(sessionRecord?.needsReopen == true ? "会话需要重新打开" : "会话不存在或已过期")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(sessionRecord?.needsReopen == true
                         ? "接管后可显式打开页面；旧页面和旧动作不会自动恢复。"
                         : "返回 Agent 浏览器任务列表重新打开。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AmberTheme.surface2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmberTheme.surface)
        .layoutPriority(1)
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView(value: runtime.snapshot.estimatedProgress)
                    .tint(AmberTheme.accent)
            }
        }
    }

    private var bridgeSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "页面内容")
            AmberFormGroup {
                AmberGlassGroup(spacing: WebMountActionLayout.glassInteractionSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WebMountActionLayout.minimumButtonSpacing) {
                            bridgeActionButtons
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: WebMountActionLayout.minimumButtonSpacing) {
                            bridgeActionButtons
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Picker("页面内容", selection: $selectedResultTab) {
                    ForEach(WebMountResultTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                if let contentHandoff, selectedResultTab == .text {
                    WebMountHandoffActions(
                        handoff: contentHandoff,
                        onChat: {
                            IOSWebMountContentHandoffStore.shared.prepareChat(contentHandoff)
                            router.navigate(to: .chat)
                        },
                        onDeepRead: {
                            IOSWebMountContentHandoffStore.shared.prepareDeepRead(contentHandoff)
                            router.navigate(to: .board)
                        }
                    )
                    WebMountDivider()
                }
                WebMountCodeBlock(text: self.selectedResultText)
                WebMountDivider()
                AmberGlassGroup(spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("选择器", text: $getSelector)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
                            .autocorrectionDisabled()
                            .disabled(!canReadPage)
                        Button("读取") { Task { await getElement() } }
                            .buttonStyle(.glass)
                            .frame(minHeight: 44)
                            .disabled(!canReadPage)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if !getText.isEmpty {
                    WebMountDivider()
                    WebMountCodeBlock(text: getText)
                }
            }
        }
    }

    private var cookieSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "登录状态")
            AmberFormGroup {
                WebMountInfoRow(
                    title: "Cookie",
                    subtitle: cookieSubtitle,
                    systemImage: "circle.grid.cross",
                    tint: AmberTheme.accentAmber,
                    trailing: cookieSummary.map { "\($0.cookieCount)" } ?? "..."
                )
                WebMountDivider()
                AmberGlassGroup(spacing: WebMountActionLayout.glassInteractionSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WebMountActionLayout.minimumButtonSpacing) {
                            cookieActionButtons
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: WebMountActionLayout.minimumButtonSpacing) {
                            cookieActionButtons
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                WebMountDivider()
                Button(role: .destructive) {
                    Task { await clearSession() }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("清除本站登录状态")
                        Spacer()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(!canUserMutate)
                .opacity(canUserMutate ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var cookieActionButtons: some View {
        Button {
            Task { await openSite() }
        } label: {
            Label("打开网页登录", systemImage: "person.badge.key")
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
        .disabled(!canUserMutate)

        Button {
            Task { await refreshCookieSummary() }
        } label: {
            Label("重新检测 Cookie", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
    }

    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                controlOwnerDetails
                controlOwnerAction
            }
            VStack(alignment: .leading, spacing: 8) {
                controlOwnerDetails
                HStack {
                    Spacer(minLength: 0)
                    controlOwnerAction
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var controlOwnerDetails: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: controlOwnerImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(controlOwnerTint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(controlOwnerTitle)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(controlOwnerSubtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var controlOwnerAction: some View {
        if sessionRecord != nil, sessionRecord?.controlOwner != .user {
            Button("接管") { takeUserControl() }
                .buttonStyle(.glassProminent)
                .frame(minHeight: 44)
                .accessibilityLabel("接管 WebMount 页面")
        } else if sessionRecord?.controlOwner == .user {
            let hasActiveAgent = sessionRecord?.ownerRunId?.nilIfBlank != nil
            Button(hasActiveAgent ? "恢复自动" : "释放控制") { handBackToAgent() }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
                .accessibilityLabel(hasActiveAgent ? "恢复 Agent 自动浏览" : "释放 WebMount 页面控制权")
        }
    }

    private var statusImage: String {
        if !hasBoundSession || sessionRecord == nil {
            return "rectangle.slash"
        }
        if sessionRecord?.needsReopen == true {
            return "arrow.clockwise"
        }
        switch runtime.snapshot.status {
        case .idle: return "circle"
        case .loading: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        if !hasBoundSession || sessionRecord == nil {
            return "会话已失效"
        }
        if sessionRecord?.needsReopen == true {
            return "需要重新打开"
        }
        switch runtime.snapshot.status {
        case .idle: return "待打开"
        case .loading: return "正在加载"
        case .ready: return "已就绪"
        case .failed: return "加载失败"
        }
    }

    private var statusTint: Color {
        if !hasBoundSession || sessionRecord == nil {
            return AmberTheme.accentRed
        }
        if sessionRecord?.needsReopen == true {
            return AmberTheme.accentAmber
        }
        switch runtime.snapshot.status {
        case .idle: return AmberTheme.muted2
        case .loading: return AmberTheme.accentAmber
        case .ready: return AmberTheme.accentGreen
        case .failed: return AmberTheme.accentRed
        }
    }

    private var statusSubtitle: String {
        if !hasBoundSession || sessionRecord == nil {
            return "目标 session 不存在或已过期"
        }
        if sessionRecord?.needsReopen == true {
            return sessionRecord?.redactedURL.nilIfBlank ?? "旧页面不会自动恢复"
        }
        return runtime.snapshot.currentURL ?? runtime.snapshot.requestedURL ?? resolvedSite.homepageURL
    }

    private var cookieSubtitle: String {
        guard let cookieSummary else { return "正在读取 Cookie 摘要" }
        let names = cookieSummary.cookieNames.isEmpty ? "无" : cookieSummary.cookieNames.joined(separator: ", ")
        let login = cookieSummary.hasLoginCookie.map { $0 ? "已检测到登录 Cookie" : "未检测到登录 Cookie" } ?? "登录状态未知"
        return "\(login) · \(names)"
    }

    private var selectedResultText: String {
        switch selectedResultTab {
        case .text:
            return extractText.nilIfBlank ?? "尚未提取正文。"
        case .links:
            return linksText.nilIfBlank ?? "尚未读取链接。"
        case .interactive:
            return interactiveText.nilIfBlank ?? "尚未观察可交互元素。"
        case .visual:
            return visualSnapshotText.nilIfBlank ?? "尚未读取视觉快照。"
        case .debug:
            return debugJSONText.nilIfBlank ?? bridgeState.nilIfBlank ?? "尚无调试 JSON。"
        }
    }

    private var loginBadgeText: String {
        guard let cookieSummary else { return "登录状态未知" }
        if cookieSummary.hasLoginCookie == true { return "已登录" }
        if cookieSummary.hasLoginCookie == false { return "未登录" }
        return "登录状态未知"
    }

    private var loginBadgeTint: Color {
        guard let cookieSummary else { return AmberTheme.muted2 }
        if cookieSummary.hasLoginCookie == true { return AmberTheme.accentGreen }
        if cookieSummary.hasLoginCookie == false { return AmberTheme.accentRed }
        return AmberTheme.accentAmber
    }

    private var controlOwnerBadgeText: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent 控制"
        case .user: "用户控制"
        default: "控制权空闲"
        }
    }

    private var controlOwnerTitle: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent 控制中"
        case .user: "你正在控制"
        default: "控制权空闲"
        }
    }

    private var controlOwnerSubtitle: String {
        if !hasBoundSession || sessionRecord == nil {
            return "当前 session 已失效，请返回站点列表重新打开。"
        }
        switch sessionRecord?.controlOwner {
        case .agent:
            return "页面仍可观察；打开、导航和网页交互需先接管。"
        case .user:
            if sessionRecord?.ownerRunId?.nilIfBlank != nil {
                return "完成登录、验证码、CAPTCHA 或支付敏感步骤后点“恢复自动”；Amber 不会自动夺回控制。"
            }
            return "你可以操作页面；当前没有活动 Agent 任务。"
        default:
            return "没有活动控制方。"
        }
    }

    private var controlOwnerImage: String {
        switch sessionRecord?.controlOwner {
        case .agent: "cursorarrow"
        case .user: "person.crop.circle"
        default: "lock.open"
        }
    }

    private var controlOwnerTint: Color {
        switch sessionRecord?.controlOwner {
        case .agent: AmberTheme.accentIndigo
        case .user: AmberTheme.accentGreen
        default: AmberTheme.muted2
        }
    }

    private var workspaceControlOwnerLabel: String {
        switch sessionRecord?.controlOwner {
        case .agent: "Agent"
        case .user: "用户"
        default: "空闲"
        }
    }

    private var workspaceControlActionLabel: String {
        guard sessionRecord?.controlOwner == .user else { return "接管" }
        return sessionRecord?.ownerRunId?.nilIfBlank == nil ? "释放" : "自动"
    }

    private var workspaceControlAccessibilityLabel: String {
        guard sessionRecord?.controlOwner == .user else { return "接管 WebMount 页面" }
        return sessionRecord?.ownerRunId?.nilIfBlank == nil
            ? "释放 WebMount 页面控制权"
            : "恢复 Agent 自动浏览"
    }

    private func openSite() async {
        guard canUserMutate else {
            if isAgentControlActive {
                banner = "Agent 正在控制此页面，请先接管。"
            }
            return
        }
        if isUnlistedWatchSession {
            await openTypedURL()
            return
        }
        observationRequestID = nil
        isLoading = true
        _ = await controller.openForUser(site: resolvedSite, sessionId: runtime.snapshot.sessionId)
        openURLText = runtime.snapshot.currentURL ?? resolvedSite.homepageURL
        isLoading = false
        if let error = runtime.snapshot.error?.nilIfBlank {
            banner = IOSWebMountRedactor.redactedText(error)
        }
    }

    private func openTypedURL() async {
        guard canUserMutate else {
            banner = "Agent 正在控制此页面，请先接管。"
            return
        }
        observationRequestID = nil
        isLoading = true
        var input: [String: Any] = [
            "url": openURLText,
            "session_id": runtime.snapshot.sessionId
        ]
        if !isUnlistedWatchSession {
            input["site_id"] = resolvedSite.id
        }
        let output = await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json(input),
            isUserInitiated: true,
            allowUnlistedHosts: isUnlistedWatchSession && highRiskAutoApprove
        )
        isLoading = false
        if let object = Self.jsonObject(output),
           object["ok"] as? Bool == false {
            banner = object["reason"] as? String ?? object["error"] as? String ?? "打开失败。"
        } else {
            banner = nil
            openURLText = runtime.snapshot.currentURL ?? openURLText
        }
    }

    private func refreshCookieSummary() async {
        cookieSummary = await controller.cookieStore.summary(for: resolvedSite)
    }

    private func readState() async {
        do {
            let state = try await runtime.state()
            bridgeState = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(state))
            debugJSONText = bridgeState
            selectedResultTab = .debug
        } catch {
            bridgeState = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = bridgeState
            selectedResultTab = .debug
        }
    }

    private func extractReadable() async {
        do {
            let result = try await runtime.extract(mode: "readable", maxChars: 4_000, maxLinks: 12)
            let redacted = IOSWebMountRedactor.redactedJSONObject(result)
            extractText = IOSWebMountRedactor.redactedText((result["text"] as? String) ?? "")
            linksText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["links"] ?? []))
            debugJSONText = IOSWebMountController.json(redacted)
            contentHandoff = IOSWebMountContentHandoff.from(
                site: resolvedSite,
                snapshot: runtime.snapshot,
                extraction: result
            )
            IOSWebMountActivityStore.shared.recordExtraction(
                siteName: resolvedSite.displayName,
                title: result["title"] as? String,
                characterCount: extractText.count,
                linkCount: (result["links"] as? [[String: Any]])?.count ?? 0
            )
            selectedResultTab = .text
        } catch {
            extractText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = extractText
            contentHandoff = nil
            selectedResultTab = .debug
        }
    }

    private func observePage() async {
        let requestID = UUID()
        observationRequestID = requestID
        defer {
            if observationRequestID == requestID { observationRequestID = nil }
        }
        do {
            let observation = try await runtime.observe(maxChars: 2_000, maxLinks: 20)
            guard observationRequestID == requestID else { return }
            let visibleText = IOSWebMountRedactor.redactedText((observation["visible_text"] as? String) ?? "")
            extractText = visibleText
            linksText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["links"] ?? []))
            interactiveText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["interactive_elements"] ?? []))
            visualSnapshotText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation["visual_candidates"] ?? []))
            debugJSONText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(observation))
            if let page = observation["page"] as? [String: Any] {
                bridgeState = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(page))
            }
            let extraction: [String: Any] = [
                "text": visibleText,
                "links": observation["links"] ?? [],
                "title": (observation["page"] as? [String: Any])?["title"] as? String ?? "",
                "url": (observation["page"] as? [String: Any])?["url"] as? String ?? ""
            ]
            contentHandoff = IOSWebMountContentHandoff.from(
                site: resolvedSite,
                snapshot: runtime.snapshot,
                extraction: extraction
            )
            IOSWebMountActivityStore.shared.recordExtraction(
                siteName: resolvedSite.displayName,
                title: extraction["title"] as? String,
                characterCount: visibleText.count,
                linkCount: (observation["links"] as? [[String: Any]])?.count ?? 0
            )
            controller.sessionStore.touch(sessionId: runtime.snapshot.sessionId, makeCurrent: false)
            selectedResultTab = .interactive
        } catch {
            guard observationRequestID == requestID else { return }
            debugJSONText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            selectedResultTab = .debug
        }
    }

    private func visualSnapshot() async {
        do {
            let result = try await runtime.extract(mode: "snapshot", maxChars: 4_000, maxLinks: 24)
            visualSnapshotText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["visual_candidates"] ?? result))
            interactiveText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result["interactive_nodes"] ?? []))
            debugJSONText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result))
            selectedResultTab = .visual
        } catch {
            visualSnapshotText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = visualSnapshotText
            selectedResultTab = .debug
        }
    }

    private func getElement() async {
        do {
            let result = try await runtime.get(
                selector: getSelector,
                target: nil,
                kind: "text",
                attrName: nil,
                maxChars: 4_000
            )
            getText = IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(result))
            debugJSONText = getText
        } catch {
            getText = IOSWebMountController.json(["ok": false, "error": IOSWebMountRedactor.redactedText(error.localizedDescription)])
            debugJSONText = getText
        }
    }

    private func clearSession() async {
        guard canUserMutate else {
            banner = "Agent 正在控制此页面，请先接管。"
            return
        }
        let result = await controller.cookieStore.clearSession(for: resolvedSite)
        banner = "已清除 \(result.deletedCookieCount) 个 Cookie 和 \(result.clearedWebsiteDataRecords) 条网页数据。"
        await refreshCookieSummary()
    }

    private func takeUserControl() {
        do {
            _ = try controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
            banner = "已接管此站点页面。"
        } catch {
            banner = "接管失败：\(IOSWebMountRedactor.redactedText(error.localizedDescription))"
        }
    }

    private func handBackToAgent() {
        let resumesAutomation = sessionRecord?.ownerRunId?.nilIfBlank != nil
        do {
            _ = try controller.sessionStore.handBackToAgent(sessionId: runtime.snapshot.sessionId)
            banner = resumesAutomation ? "已恢复 Agent 自动浏览。" : "已释放此站点页面控制权。"
        } catch {
            let action = resumesAutomation ? "恢复自动" : "释放"
            banner = "\(action)失败：\(IOSWebMountRedactor.redactedText(error.localizedDescription))"
        }
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
private struct WebMountRuntimeWebView: UIViewRepresentable {
    let runtime: IOSWebMountWKRuntime
    let isInteractive: Bool

    func makeUIView(context: Context) -> WKWebView {
        let webView = runtime.webView ?? WKWebView()
        webView.isUserInteractionEnabled = isInteractive
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.isUserInteractionEnabled = isInteractive
    }
}

private struct WebMountBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct WebMountStationRow: View {
    let site: IOSWebMountSite
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.displayName)
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                        Text("\(authKindText) · \(IOSWebMountRedactor.redactedURL(site.homepageURL) ?? site.homepageURL)")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            WebMountAccessibleSwitch(
                isOn: Binding(
                get: { site.enabled },
                set: { value in
                    Task { @MainActor in onToggle(value) }
                }
                ),
                label: "启用 \(site.displayName)",
                hint: site.enabled ? "关闭后 Agent 不再打开此站点" : "打开后允许 Agent 使用此站点"
            )

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(site.displayName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var iconName: String {
        switch site.authKind {
        case .anonymous: "globe"
        case .cookie: "person.badge.key"
        case .oauth: "key"
        }
    }

    private var authKindText: String {
        switch site.authKind {
        case .anonymous: "无需登录"
        case .cookie: "Cookie 登录"
        case .oauth: "OAuth 登录"
        }
    }

    private var iconColor: Color {
        switch site.authKind {
        case .anonymous: AmberTheme.accentGreen
        case .cookie: AmberTheme.accentAmber
        case .oauth: AmberTheme.accentIndigo
        }
    }
}

private struct WebMountToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WebMountAccessibleSwitch(isOn: $isOn, label: title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

@MainActor
private struct WebMountAccessibleSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    let label: String
    var hint: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.onTintColor = UIColor(AmberTheme.accent)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.setOn(isOn, animated: false)
        control.onTintColor = UIColor(AmberTheme.accent)
        control.accessibilityLabel = label
        control.accessibilityHint = hint
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func valueChanged(_ sender: UISwitch) {
            isOn.wrappedValue = sender.isOn
        }
    }
}

private struct WebMountInfoRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let trailing: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                infoLeading
                infoTrailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                infoLeading
                infoTrailing
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var infoLeading: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var infoTrailing: some View {
        Text(trailing)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .multilineTextAlignment(.trailing)
    }
}

private struct WebMountHandoffActions: View {
    let handoff: IOSWebMountContentHandoff
    let onChat: () -> Void
    let onDeepRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已提取 \(handoff.text.count) 个字符，可转入下一步。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(2)

            AmberGlassGroup(spacing: WebMountActionLayout.glassInteractionSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WebMountActionLayout.minimumButtonSpacing) {
                        handoffButtons
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: WebMountActionLayout.minimumButtonSpacing) {
                        handoffButtons
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var handoffButtons: some View {
        Button(action: onChat) {
            Label("转入聊天", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)

        Button(action: onDeepRead) {
            Label("转入深度阅读", systemImage: "book.pages")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
    }
}

private struct WebMountTextFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 88, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct WebMountCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AmberTheme.foreground2)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct WebMountDivider: View {
    var body: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, 58)
    }
}

private struct WebMountBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(AmberTheme.foreground2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
            .padding(.horizontal, 16)
    }
}

#Preview {
    NavigationStack {
        WebMountView()
    }
}

#Preview("WebMount Site") {
    NavigationStack {
        WebMountSiteView(site: .init(siteId: "hackernews", name: "Hacker News", host: "news.ycombinator.com"))
    }
}
