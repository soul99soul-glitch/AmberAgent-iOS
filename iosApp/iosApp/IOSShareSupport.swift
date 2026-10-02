import Shared
import SwiftUI
import UIKit
import WebKit

/// 从菜单、异步导出等非声明式入口弹出系统分享面板。能直接用 `ShareLink` 的地方仍优先用 `ShareLink`。
@MainActor
enum IOSShareSheet {
    /// 返回 false 表示面板没有真正弹出（例如另一个界面仍在收起或已有分享面板），调用方需给出可见提示。
    static func present(_ items: [Any]) async -> Bool {
        guard !items.isEmpty else { return false }
        // 从 contextMenu/Menu 动作里触发时，菜单或上一个面板可能还在收起；等它落位再弹，最多约 1 秒。
        for _ in 0..<20 {
            guard let top = topViewController(), top.isBeingDismissed || top.isBeingPresented
                    || top.presentedViewController?.isBeingDismissed == true else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let presenter = topViewController(),
              !(presenter is UIActivityViewController) else { return false }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in IOSShareActivity.shared.shareSheetDidDismiss() }
        }
        presenter.present(controller, animated: true)
        // UIKit 拒绝呈现时只打日志、不会挂上 presentedViewController。
        guard presenter.presentedViewController === controller else { return false }
        IOSShareActivity.shared.shareSheetDidAppear(controller)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// 分享/导出进行中的全局状态：同一时间只允许一个任务（`isWorking`），并驱动浮层的可见反馈。
@MainActor
@Observable
final class IOSShareActivity {
    static let shared = IOSShareActivity()
    static let maxQueuedFailures = 3

    enum Status: Equatable {
        case working(String)
        case failed(String)
    }

    private(set) var status: Status? {
        didSet {
            guard status != oldValue, let status else { return }
            switch status {
            case .working(let message), .failed(let message):
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
    /// 即时提示（如“正在处理上一个分享”），立刻显示约 2 秒后恢复原状态，不排队、不会过时。
    private(set) var notice: String? {
        didSet {
            guard notice != oldValue, let notice else { return }
            AccessibilityNotification.Announcement(notice).post()
        }
    }
    /// 任务互斥与显示解耦：很快完成的任务（如分享文本）可以不显示进度，但仍占住互斥。
    private(set) var isWorking = false
    private var flashTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// 进行中或分享面板遮挡期间发生的失败，等可见时再显示，不丢反馈。
    private var queuedFailures: [String] = []
    /// 用面板本身判断是否仍在屏幕上，而不是单独维护布尔：面板被任何方式移除后都能自愈。
    private weak var shareSheet: UIViewController?

    private var isShareSheetVisible: Bool {
        guard let shareSheet else { return false }
        return shareSheet.presentingViewController != nil && !shareSheet.isBeingDismissed
    }

    /// `message` 为 nil 时不显示进度（避免瞬时任务闪一下并重复播报）。
    /// 已有任务进行时返回 false；调用方应改用 `notify` 给出即时提示，而不是静默返回。
    func begin(_ message: String? = nil) -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        flashTask?.cancel()
        status = message.map(Status.working)
        return true
    }

    func end(failure: String? = nil) {
        isWorking = false
        if let failure {
            queuedFailures.insert(failure, at: 0)
        }
        showQueuedFailuresIfVisible()
    }

    /// 任务失败的提示：当前不可见（进行中或被分享面板盖住）时排队，可见后显示。
    func flash(failure: String) {
        queuedFailures.append(failure)
        showQueuedFailuresIfVisible()
    }

    func notify(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func shareSheetDidAppear(_ controller: UIViewController) {
        shareSheet = controller
    }

    func shareSheetDidDismiss() {
        shareSheet = nil
        showQueuedFailuresIfVisible()
    }

    /// 停留时长随文案长度 3–5 秒，长文案读得完。
    nonisolated static func displayDuration(for message: String) -> Duration {
        .seconds(max(3, min(5, Double(message.count) * 0.12)))
    }

    private func showQueuedFailuresIfVisible() {
        guard !isWorking else { return }
        flashTask?.cancel()
        if isShareSheetVisible {
            // 面板盖住浮层：先攒着（最多几条，避免无限累积），面板收起后再显示。
            status = nil
            queuedFailures = Array(queuedFailures.prefix(Self.maxQueuedFailures))
            return
        }
        guard !queuedFailures.isEmpty else {
            status = nil
            return
        }
        var unique: [String] = []
        for failure in queuedFailures where !unique.contains(failure) {
            unique.append(failure)
        }
        queuedFailures.removeAll()
        let message = unique.prefix(Self.maxQueuedFailures).joined(separator: "；")
        status = .failed(message)
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration(for: message))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    #if DEBUG
    func resetForTesting() {
        flashTask?.cancel()
        noticeTask?.cancel()
        isWorking = false
        queuedFailures.removeAll()
        shareSheet = nil
        status = nil
        notice = nil
    }
    #endif
}

/// 分享/导出的进度与失败提示，App 根视图单点挂载。样式与深读页顶部 toast 一致；
/// 放在顶部是为了不与聊天输入框、键盘争位置，且不拦截下层点击。
struct IOSShareActivityOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            IOSShareActivityBanner()
        }
    }
}

private struct IOSShareActivityBanner: View {
    private let activity = IOSShareActivity.shared
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        ZStack {
            if activity.notice != nil || activity.status != nil {
                // 图标与第一行文字对齐，两行文案时不居中下沉。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let notice = activity.notice {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(AmberTheme.accent)
                        Text(notice)
                    } else if let status = activity.status {
                        switch status {
                        case .working(let message):
                            ProgressView().controlSize(.small)
                            Text(message)
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AmberTheme.accentRed)
                            Text(message)
                        }
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(AmberTheme.border.opacity(0.4), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                .padding(.horizontal, 24)
                // 让开聊天顶栏（controlsHeight 54）与深读顶栏（44 + 上下内边距）。
                .padding(.top, ChatTopBarLayout.controlsHeight + 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: activity.status)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: activity.notice)
        .allowsHitTesting(false)
        .ignoresSafeArea(.keyboard)
    }
}

extension View {
    func iosShareActivityOverlay() -> some View {
        modifier(IOSShareActivityOverlay())
    }
}

/// 分享/导出链路里的用户可读错误。
struct IOSShareError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum IOSConversationExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case pdf

    var id: String { rawValue }

    /// 出现在「导出对话」子菜单里，动词已由父菜单给出。
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .pdf: "PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.plaintext"
        case .pdf: "doc.richtext"
        }
    }
}

/// 整段对话 → Markdown / PDF 文件，交给系统分享面板。
@MainActor
enum IOSConversationExporter {
    struct Entry: Equatable, Sendable {
        enum Role: Equatable, Sendable { case user, assistant }
        let role: Role
        let text: String
        let imageCount: Int
    }

    /// 与气泡显示一致的文本：用户消息去掉邮箱桥接与可视化路由标记，助手消息取正文。
    /// 单条分享与整段导出共用，避免把内部标记带出 App。
    static func shareText(for message: UIMessage) -> String {
        guard message.role == MessageRole.user else { return message.toText() }
        return message.parts.compactMap { part -> String? in
            guard let textPart = part as? UIMessagePart.Text, !textPart.text.isEmpty else { return nil }
            return GenerativeUiPlanner.shared.stripVisualRouteTagsForDisplay(
                text: IosMailboxMessageBridge.shared.displayText(part: textPart)
            )
        }.joined(separator: "\n\n")
    }

    static func entries(from messages: [UIMessage]) -> [Entry] {
        messages.compactMap { message in
            let role: Entry.Role
            switch message.role {
            case MessageRole.user: role = .user
            case MessageRole.assistant: role = .assistant
            default: return nil
            }
            let imageCount = message.parts.filter { $0 is UIMessagePart.Image }.count
            let trimmed = shareText(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || imageCount > 0 else { return nil }
            return Entry(role: role, text: trimmed, imageCount: imageCount)
        }
    }

    nonisolated static func markdown(title: String, entries: [Entry], exportedAt: Date = Date()) -> String {
        var lines = ["# \(title)", "", "> 导出自 Amber · \(exportedAt.formatted(date: .abbreviated, time: .shortened))", ""]
        for entry in entries {
            lines.append(entry.role == .user ? "### 我" : "### Amber")
            lines.append("")
            if entry.imageCount > 0 {
                lines.append("*[\(entry.imageCount) 张图片]*")
                lines.append("")
            }
            if !entry.text.isEmpty {
                lines.append(entry.text)
                lines.append("")
            }
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 纯字符串拼接 + Markdown 解析（无状态 FFI），可在后台执行。
    nonisolated static func html(title: String, entries: [Entry], exportedAt: Date = Date()) -> String {
        var body = "<h1 class=\"doc-title\">\(escape(title))</h1><p class=\"meta\">导出自 Amber · \(escape(exportedAt.formatted(date: .abbreviated, time: .shortened)))</p>"
        for entry in entries {
            let role = entry.role == .user ? "user" : "assistant"
            body += "<section class=\"msg \(role)\"><div class=\"role\">\(entry.role == .user ? "我" : "Amber")</div><div class=\"body\">"
            if entry.imageCount > 0 {
                body += "<p class=\"meta\">[\(entry.imageCount) 张图片]</p>"
            }
            body += IOSDeepReadEditorialRenderer.markdownToHTML(entry.text)
            body += "</div></section>"
        }
        return IOSHTMLPDFRenderer.document(body: body)
    }

    static func export(
        format: IOSConversationExportFormat,
        title rawTitle: String,
        messages: [UIMessage]
    ) async throws -> URL {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Amber 对话" : rawTitle
        let entries = entries(from: messages)
        guard !entries.isEmpty else { throw ExportError.empty }
        let data: Data
        switch format {
        case .markdown:
            data = await Task.detached(priority: .userInitiated) {
                Data(markdown(title: title, entries: entries).utf8)
            }.value
        case .pdf:
            let html = await Task.detached(priority: .userInitiated) {
                html(title: title, entries: entries)
            }.value
            data = try await IOSHTMLPDFRenderer.render(html: html)
        }
        return try IOSShareFileWriter.write(data, fileName: title, pathExtension: format == .pdf ? "pdf" : "md")
    }

    /// 生成文件并弹出分享面板；进度与失败都经 `IOSShareActivity` 浮层呈现。
    static func share(format: IOSConversationExportFormat, title: String, messages: [UIMessage]) async {
        await share(format: format, title: title, loadMessages: { .loaded(messages) })
    }

    enum MessageLoad {
        case loaded([UIMessage])
        /// 读取失败，message 由浮层直接显示（存储层的错误弹窗只挂在聊天页，不能指望它）。
        case failed(String)
    }

    static let busyMessage = "正在处理上一个分享，请稍后再试。"

    /// 先显示进度再取消息：会话列表导出需要从存储读取，读取期间也要有反馈和防重入。
    static func share(
        format: IOSConversationExportFormat,
        title: String,
        loadMessages: () async -> MessageLoad
    ) async {
        let activity = IOSShareActivity.shared
        guard activity.begin(format == .pdf ? "正在生成 PDF…" : "正在导出 Markdown…") else {
            activity.notify(busyMessage)
            return
        }
        let messages: [UIMessage]
        switch await loadMessages() {
        case .loaded(let loaded):
            messages = loaded
        case .failed(let message):
            activity.end(failure: message)
            return
        }
        do {
            let url = try await export(format: format, title: title, messages: messages)
            activity.end(failure: await IOSShareSheet.present([url]) ? nil : "当前无法弹出分享面板，请稍后重试。")
        } catch {
            activity.end(failure: error.localizedDescription)
        }
    }

    enum ExportError: LocalizedError {
        case empty

        var errorDescription: String? { "这段对话还没有可导出的内容。" }
    }

    nonisolated private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 单条消息 → 分享卡片图片。只渲染行内 Markdown（加粗、代码、链接等），去掉代码围栏行，表格/公式按原文呈现。
@MainActor
enum IOSMessageImageRenderer {
    /// 同时限制字数与行数，控制位图尺寸：390pt 宽、2x 时约 150 行对应 20MB 左右。
    nonisolated static let maxCharacters = 3_000
    nonisolated static let maxLines = 120

    nonisolated static func preparedText(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var truncated = false
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maxCharacters {
            result = String(result.prefix(maxCharacters))
            truncated = true
        }
        return truncated ? result + "\n…（内容过长，已截断）" : result
    }

    static func render(text: String, isUser: Bool) -> UIImage? {
        let prepared = preparedText(text)
        guard !prepared.isEmpty else { return nil }
        let attributed = (try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prepared)
        let renderer = ImageRenderer(content: IOSMessageShareCard(text: attributed, isUser: isUser))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: IOSMessageShareCard.width, height: nil)
        return renderer.uiImage
    }
}

private struct IOSMessageShareCard: View {
    static let width: CGFloat = 390

    let text: AttributedString
    let isUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isUser ? "我" : "Amber")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(AmberTheme.foreground)
                .tint(AmberTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(isUser ? 12 : 0)
                .background {
                    if isUser {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AmberTheme.accentTint)
                    }
                }
            Divider()
            Text("由 Amber 分享")
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
        }
        .padding(24)
        .frame(width: Self.width, alignment: .leading)
        .background(AmberTheme.background)
        .environment(\.colorScheme, .light)
    }
}
