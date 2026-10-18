import SwiftUI

struct WebMountSiteMemoryApprovalMinimumHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

struct WebMountToolApprovalCard: View {
    let request: WebMountToolApprovalRequest
    let onOpenSession: (() -> Void)?
    let onApprove: () -> Void
    let onDeny: () -> Void
    var maximumHeight: CGFloat = .infinity
    var jevReviewReasons: [String]? = nil
    var jevTriage: IOSJevApprovalTriage? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var decisionRowHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let changes = request.siteMemoryChanges {
                WebMountSiteMemoryApprovalDetails(
                    request: request, changes: changes,
                    maximumHeight: max(0, min(maximumHeight, dynamicTypeSize.isAccessibilitySize ? 520 : 420) - decisionRowHeight - 1),
                    jevReviewReasons: jevReviewReasons, jevTriage: jevTriage
                )
            } else {
                approvalDetails
            }

            if request.siteMemoryChanges != nil {
                Divider().overlay(AmberTheme.borderSoft).padding(.horizontal, 14)
            } else {
                WebMountDivider()
            }

            HStack(spacing: 10) {
                denyButton
                approveButton
            }
            .fixedSize(horizontal: false, vertical: request.siteMemoryChanges != nil)
            .padding(12)
            .onGeometryChange(for: CGFloat.self) { request.siteMemoryChanges == nil ? 0 : $0.size.height } action: { decisionRowHeight = $0 }
            .preference(key: WebMountSiteMemoryApprovalMinimumHeightKey.self,
                        value: request.siteMemoryChanges == nil ? [:]
                            : [request.id: decisionRowHeight + max(44, decisionRowHeight - 24) + 28 + 1])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var approvalDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(AmberTheme.accent)
                        .frame(width: 8, height: 8)
                    Text("WebMount 请求")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                }

                Text(IOSAppLocalization.string(request.title))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            WebMountDivider()

            VStack(alignment: .leading, spacing: 14) {
                approvalTextBlock(label: "意图", value: displayReason)

                VStack(alignment: .leading, spacing: 6) {
                    approvalSectionLabel("目标页面")
                    HStack(spacing: 7) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                        Text(request.redactedURL.nilIfBlank ?? request.host)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AmberTheme.foreground2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 7) {
                    approvalSectionLabel("本次范围")
                    approvalScopeRow(label: "站点", value: "\(request.siteName) · \(request.host)")
                    approvalScopeRow(label: "动作", value: IOSAppLocalization.string(request.action))
                    approvalScopeRow(label: "影响", value: IOSAppLocalization.string(request.consequence))
                    approvalScopeRow(label: "环境", value: backendTitle)
                    if let target = request.target?.nilIfBlank {
                        approvalScopeRow(label: "目标", value: target)
                    }
                }

                if let changes = request.siteMemoryChanges, !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        approvalSectionLabel("将保存的条目变更")
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            Text(change)
                                .font(.caption)
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(request.requiresHumanHandoff ? AmberTheme.accentAmber : AmberTheme.accentGreen)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Text(IOSAppLocalization.string(riskSummary))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let warning = request.screenshotRetentionWarning?.nilIfBlank {
                    Label(IOSAppLocalization.string(warning), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.accentAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            if let onOpenSession {
                WebMountDivider()
                Button(action: onOpenSession) {
                    HStack(spacing: 8) {
                        Label(
                            IOSAppLocalization.string(openSessionLabel),
                            systemImage: request.backend == IOSWebMountBackendKind.local.rawValue ? "eye" : "macwindow"
                        )
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: request.siteMemoryChanges == nil ? nil : .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(IOSAppLocalization.formatted("%@，不会批准或继续当前动作", arguments: [IOSAppLocalization.string(openSessionLabel)]))
            }

        }
    }

    private var denyButton: some View {
        Button(action: onDeny) {
            Text("拒绝")
                .font((request.siteMemoryChanges == nil ? Font.body : Font.subheadline).weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: request.siteMemoryChanges == nil ? nil : .infinity)
                .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(request.siteMemoryChanges == nil ? "拒绝 WebMount 前台动作" : "拒绝站点记忆变更")
        .accessibilityIdentifier("webmount-approval-deny")
    }

    private var approveButton: some View {
        Button(action: onApprove) {
            Text(IOSAppLocalization.string(approveLabel))
                .font((request.siteMemoryChanges == nil ? Font.body : Font.subheadline).weight(.semibold))
                .lineLimit(request.siteMemoryChanges == nil ? 1 : 2)
                .minimumScaleFactor(request.siteMemoryChanges == nil ? 0.7 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: request.siteMemoryChanges == nil ? nil : .infinity)
                .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(request.siteMemoryChanges == nil
            ? IOSAppLocalization.string(approveLabel)
            : IOSAppLocalization.string("保存站点记忆变更"))
        .accessibilityIdentifier("webmount-approval-confirm")
    }

    private func approvalSectionLabel(_ text: String) -> some View {
        Text(IOSAppLocalization.string(text))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
    }

    private func approvalTextBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            approvalSectionLabel(label)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func approvalScopeRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(IOSAppLocalization.string(label))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .frame(minWidth: 30, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayReason: String {
        guard request.requiresHumanHandoff else { return request.reason }
        return IOSAppLocalization.string("请前往本机 WebMount 完成登录、验证码/CAPTCHA 或支付等敏感步骤，然后将控制权交还给 Agent。")
    }

    private var approveLabel: String {
        if request.siteMemoryChanges != nil { return dynamicTypeSize.isAccessibilitySize ? "保存" : "保存变更" }
        return request.requiresHumanHandoff ? "完成并继续" : "批准"
    }

    private var openSessionLabel: String {
        request.backend == IOSWebMountBackendKind.local.rawValue ? "观看页面" : "查看状态"
    }

    private var backendTitle: String {
        IOSWebMountBackendKind(rawValue: request.backend)?.title ?? request.backend
    }

    private var riskSummary: String {
        if request.requiresHumanHandoff {
            return "需要你完成登录、验证码或支付等敏感步骤；Agent 不会代为输入凭据。"
        }
        return "仅批准这一次前台动作，不扩大站点权限。"
    }
}

private struct WebMountSiteMemoryApprovalDetails: View {
    let request: WebMountToolApprovalRequest
    let changes: [String]
    let maximumHeight: CGFloat
    let jevReviewReasons: [String]?
    let jevTriage: IOSJevApprovalTriage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            details
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("site-memory-approval-changes")
        .frame(height: min(contentHeight, maximumHeight, dynamicTypeSize.isAccessibilitySize ? 400 : 340))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reasons = jevReviewReasons { JevAutoApprovalEscalationNote(reasons: reasons) }
            if let triage = jevTriage { JevApprovalTriageChips(triage: triage) }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(AmberTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("确认站点记忆变更")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(request.siteName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineLimit(2)
                    Text(request.host)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("保存以下 \(changes.count) 项变更到本机。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            changeRows

            Text("与页面实际不符时以页面为准。")
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
        }
        .padding(14)
    }

    private var changeRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                Text(change)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }
}

struct WebMountApprovalChip: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AmberTheme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 144, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background(AmberTheme.surface2.opacity(0.64), in: Capsule())
    }
}
