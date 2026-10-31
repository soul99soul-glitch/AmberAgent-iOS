import SwiftUI

struct McpToolApprovalCard: View {
    let request: McpToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void
    @State private var showsFullSkillChanges = false

    var body: some View {
        let isThemeTryOn = request.themePackPreview != nil
        let isDestructive = request.isDestructiveAppleAction || request.isDestructiveLocalMutation
        let chrome = isDestructive
            ? AmberTheme.accentRed
            : (isThemeTryOn ? AmberTheme.accent : AmberTheme.accentCyan)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome)
                    .frame(width: 30, height: 30)
                    .background(chrome.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text(request.reason)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let preview = request.skillImportPreview {
                skillImportPreview(preview)
            } else if let preview = request.soulImportPreview {
                soulImportPreview(preview)
            } else if let preview = request.mcpImportPreview {
                mcpImportPreview(preview)
            } else if let preview = request.themePackPreview {
                themePackPreview(preview)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // SSH profile 是本地能力：用中文能力名，不展示裸工具名+local 前缀。
                    let heading = request.isAppleCapability
                        ? request.displayToolName
                        : (IOSSSHProfileToolCatalog.contains(request.toolName)
                            ? request.displayToolName
                            : "\(request.serverName) / \(request.toolName)")
                    Text(heading)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineLimit(1)
                    Text(request.argumentsPreview)
                        .font(request.isAppleCapability || IOSSSHProfileToolCatalog.contains(request.toolName)
                            ? .footnote
                            : .system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(IOSAppleAgentToolCatalog.workoutToolNames.contains(request.toolName) ? 10 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AmberTheme.surface.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }

            if let warning = request.appleConsequenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AmberTheme.accentAmber.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            if request.soulImportPreview == nil
                && request.mcpImportPreview == nil
                && request.skillImportPreview == nil
                && request.themePackPreview == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        WebMountApprovalChip(systemImage: request.isAppleCapability ? "iphone" : "server.rack", title: request.serverName)
                        WebMountApprovalChip(
                            systemImage: request.isAppleCapability ? request.systemImage : "wrench.and.screwdriver",
                            title: request.displayToolName
                        )
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        WebMountApprovalChip(systemImage: request.isAppleCapability ? "iphone" : "server.rack", title: request.serverName)
                        WebMountApprovalChip(
                            systemImage: request.isAppleCapability ? request.systemImage : "wrench.and.screwdriver",
                            title: request.displayToolName
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Label(
                        request.isAppleCapability
                            && IOSAppleAgentToolCatalog.alarmToolNames.contains(request.toolName)
                            ? IOSAlarmCopy.denyButton
                            : (request.themePackPreview == nil ? "拒绝" : "还原"),
                        systemImage: request.themePackPreview == nil ? "xmark" : "arrow.uturn.backward"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel(approvalAccessibilityLabel(allow: false))

                Button(action: onApprove) {
                    Label(
                        request.toolName.hasSuffix("_cancel")
                            ? (IOSAppleAgentToolCatalog.alarmToolNames.contains(request.toolName)
                                ? IOSAlarmCopy.cancelButton
                                : "取消")
                            : (request.isAppleCapability
                                && IOSAppleAgentToolCatalog.alarmToolNames.contains(request.toolName)
                                ? IOSAlarmCopy.approveButton
                                : (isDestructive ? "删除" : (request.themePackPreview == nil ? "批准" : "套用"))),
                        systemImage: request.toolName.hasSuffix("_cancel")
                            ? "arrow.uturn.backward"
                            : (isDestructive ? "trash" : "checkmark")
                    )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 32)
                        .background(isDestructive ? AmberTheme.accentRed : AmberTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel(approvalAccessibilityLabel(allow: true))
            }
            .padding(.top, 2)
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(chrome.opacity(0.34), lineWidth: 0.7)
        }
    }

    private func approvalAccessibilityLabel(allow: Bool) -> String {
        if request.themePackPreview != nil {
            return allow ? "套用主题" : "还原主题"
        }
        let verb = allow ? "批准" : "拒绝"
        if request.soulImportPreview != nil { return "\(verb)核心指令更新" }
        if request.mcpImportPreview != nil { return "\(verb) MCP 导入" }
        if request.skillImportPreview != nil { return "\(verb) Skill 导入" }
        if request.isAppleCapability { return "\(verb)\(request.displayToolName)" }
        return "\(verb) MCP 工具"
    }

    private func themePackPreview(_ document: AmberThemePackDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            AmberThemePackMiniPreview(
                palette: (AmberThemeRuntime.Paper(rawValue: document.paper) ?? .neutral).lightPalette,
                accent: Color(hex: (try? AmberThemePackTransfer.parseHex(document.accentHex)) ?? AmberAccentOption.amberGold.accentHex),
                canvasStyle: AmberCanvasStyle(rawValue: document.canvasStyle) ?? .flat,
                paintBrandHint: document.brandMark == AmberBrandMarkStyle.paintAMBER.rawValue,
                serifBrandHint: document.brandMark == AmberBrandMarkStyle.serifWordmark.rawValue,
                design: document.design
            )
            .frame(width: 180, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func soulImportPreview(_ preview: SoulImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("核心指令变更")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            Text("\(String(preview.baseHash.prefix(10))) → \(String(preview.candidateHash.prefix(10)))")
                .font(.caption2.monospaced())
                .foregroundStyle(AmberTheme.muted)
            Text(preview.afterSummary)
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(preview.diffPreview)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func mcpImportPreview(_ preview: McpImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skill \(preview.skillName) · \(preview.servers.count) 个服务")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            ForEach(preview.servers) { server in
                Text("\(server.name) · \(server.transport) · \(server.origin)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
                if !server.headerNames.isEmpty {
                    Text("headers: \(server.headerNames.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(AmberTheme.muted2)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func skillImportPreview(_ preview: McpSkillImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(preview.skillName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(preview.mutationKind == .new ? "新建" : "更新")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(preview.mutationKind == .new ? AmberTheme.accentGreen : AmberTheme.accentAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (preview.mutationKind == .new ? AmberTheme.accentGreen : AmberTheme.accentAmber).opacity(0.12),
                        in: Capsule()
                    )
            }

            Text("导入前摘要：\(preview.beforeSummary)")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("批准后摘要：\(preview.afterSummary)")
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("包哈希  \(shortHash(preview.baseHash) ?? "无") → \(shortHash(preview.candidateHash) ?? preview.candidateHash)")
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .textSelection(.enabled)

            if !preview.changedFiles.isEmpty {
                DisclosureGroup(isExpanded: $showsFullSkillChanges) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(preview.changedFiles) { change in
                                skillFileChange(change)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Label("文件变更（\(preview.changedFiles.count) 个文件）", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentCyan)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .tint(AmberTheme.accentCyan)
            }

            if preview.containsMcpConfig {
                Label("包含 MCP 配置；批准不会自动连接。", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func skillFileChange(_ change: McpSkillImportFileChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(fileChangeTitle(change.kind))  \(change.path)")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)

            if let before = change.beforeText {
                Text("导入前\n\(before.isEmpty ? "（空文件）" : before)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .textSelection(.enabled)
            } else if change.kind != .added {
                Text("导入前内容未展示（文件较大或非文本；已纳入包哈希）")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
            if let after = change.afterText {
                Text("批准后\n\(after.isEmpty ? "（空文件）" : after)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.foreground2)
                    .textSelection(.enabled)
            } else if change.kind != .removed {
                Text("批准后内容未展示（文件较大或非文本；已纳入包哈希）")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(8)
        .background(AmberTheme.surface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func shortHash(_ hash: String?) -> String? {
        guard let hash, !hash.isEmpty else { return nil }
        return String(hash.prefix(10))
    }

    private func fileChangeTitle(_ kind: McpSkillImportFileChangeKind) -> String {
        switch kind {
        case .added: "新增"
        case .modified: "修改"
        case .removed: "删除"
        }
    }
}

/// App-shell strip when a theme try-on is live but the chat approval card is off screen.
