import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DesktopFileActions {
    @MainActor static func importConversation(_ workspace: DesktopWorkspace) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Amber 导出的 JSON 会话文件"
        if panel.runModal() == .OK, let url = panel.url { workspace.importConversation(from: url) }
    }

    @MainActor static func exportConversation(_ workspace: DesktopWorkspace) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))).json"
        if panel.runModal() == .OK, let url = panel.url { workspace.exportConversation(to: url) }
    }

    @MainActor static func exportMessage(_ workspace: DesktopWorkspace, messageID: UUID) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))) · 消息.md"
        if panel.runModal() == .OK, let url = panel.url { workspace.exportMessage(messageID, to: url) }
    }

    @MainActor static func addAttachments(_ workspace: DesktopWorkspace) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .text, .json, .sourceCode, .rtf, .html]
            + ["doc", "docx", "pptx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "添加图片、PDF、DOC/DOCX、RTF、PPTX、文本或代码文件"
        if panel.runModal() == .OK { workspace.addAttachments(panel.urls) }
    }

    @MainActor static func exportReadableConversation(_ workspace: DesktopWorkspace, format: DesktopReadableExportFormat) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .pdf ? [.pdf] : [UTType(filenameExtension: "md") ?? .plainText]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))).\(format.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.exportReadableConversation(to: url, format: format)
        }
    }
}

/// Only this view reads the live conversation, so streaming chunks re-render the transcript, not the window around it.
struct DesktopSelectedTranscript: View {
    @Bindable var workspace: DesktopWorkspace
    let focusRequest: DesktopTranscriptFocus?
    let findRequest: Int

    var body: some View {
        if let conversation = workspace.selectedConversation {
            DesktopTranscript(conversation: conversation, workspace: workspace, focusRequest: focusRequest, findRequest: findRequest)
        }
    }
}

/// Welcome suggestion card with its own clean 14pt hover state (never uses `DesktopQuietButtonStyle`, which drew a 6pt box behind 14pt corners).
struct WelcomeSuggestionButton: View {
    let title: String
    let subtitle: String
    let glyph: DesktopCraftGlyph
    let tone: DesktopCraftTone
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                DesktopCraftIcon(glyph: glyph, tone: tone, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hovering ? DesktopTheme.accent : DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(hovering ? DesktopTheme.paperSide : DesktopTheme.card, in: shape)
            .overlay(
                shape.strokeBorder(
                    hovering ? DesktopTheme.honeyEdge : DesktopTheme.hairlineStrong,
                    lineWidth: 1
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("将建议写入草稿，编辑后再发送")
    }
}

/// Top-right toolbar capsule bar that shortens when the right inspector expands and lengthens when the right
/// inspector collapses, using a bouncy Liquid Glass morph (`DesktopLiquidMotion.toolbarCapsuleTransform`) while
/// keeping the trailing `sidebar.right` toggle button at a fixed window coordinate (`ΔX = 0`).
struct DesktopToolbarLiquidCapsule: View, Animatable {
    @Bindable var workspace: DesktopWorkspace
    var extensionProgress: CGFloat
    let reduceMotion: Bool
    let inspectorVisible: Bool
    @Binding var insightsPresented: Bool
    @Binding var shelfPresented: Bool
    @Binding var filesPresented: Bool
    @Binding var tasksPresented: Bool
    @Binding var pluginInspectorPresented: Bool
    @Binding var commandPalettePresented: Bool
    let onLocateArtifact: (UUID) -> Void
    let onFocusComposer: () -> Void
    let onToggleInspector: () -> Void

    nonisolated var animatableData: CGFloat {
        get { extensionProgress }
        set { extensionProgress = newValue }
    }

    var body: some View {
        let isChat = workspace.activeSurface == .chat
        let hasPluginItem = workspace.plugins.hasInspectorPluginItems
        let extraItemCount = isChat ? (hasPluginItem ? 5 : 4) : 0
        let transform = DesktopLiquidMotion.toolbarCapsuleTransform(
            extensionProgress: isChat ? extensionProgress : 0.0,
            extraItemCount: extraItemCount,
            reduceMotion: reduceMotion
        )
        let effectiveWidth: CGFloat = isChat ? transform.width : 42.0
        let capsuleShape = DesktopLiquidCapsuleShape(waistPinch: isChat ? transform.waistPinch : 0.0)

        HStack(spacing: 0) {
            DesktopToolbarIconButton(
                systemName: "command",
                help: "命令面板 ⌘K",
                accessibilityLabel: "命令面板",
                action: { commandPalettePresented = true }
            )
            .padding(.leading, 4)

            if isChat {
                HStack(spacing: 4) {
                    collapsibleItem(index: 0, totalCount: extraItemCount) {
                        DesktopToolbarIconButton(
                            systemName: "text.bubble",
                            help: "上下文与回顾",
                            accessibilityLabel: "上下文与回顾",
                            disabled: !workspace.hasSelectedConversation || workspace.isLoading,
                            isActive: insightsPresented,
                            action: { insightsPresented.toggle() }
                        )
                        .popover(isPresented: $insightsPresented, arrowEdge: .bottom) {
                            DesktopConversationInsightsView(workspace: workspace)
                        }
                    }

                    collapsibleItem(index: 1, totalCount: extraItemCount) {
                        DesktopToolbarIconButton(
                            systemName: "pin",
                            help: "产物架",
                            accessibilityLabel: "产物架",
                            disabled: !workspace.hasSelectedConversation || workspace.isLoading,
                            isActive: shelfPresented,
                            action: { shelfPresented.toggle() }
                        )
                        .popover(isPresented: $shelfPresented, arrowEdge: .bottom) {
                            DesktopArtifactShelfView(workspace: workspace, onLocate: onLocateArtifact)
                        }
                    }

                    collapsibleItem(index: 2, totalCount: extraItemCount) {
                        DesktopToolbarIconButton(
                            systemName: "folder",
                            help: "此会话的文件与产物",
                            accessibilityLabel: "会话文件",
                            disabled: workspace.selectedID == nil || workspace.isLoading,
                            action: { filesPresented = true }
                        )
                    }

                    collapsibleItem(index: 3, totalCount: extraItemCount) {
                        DesktopToolbarIconButton(
                            systemName: "checklist",
                            help: "工具任务与待确认操作",
                            accessibilityLabel: "任务工作台",
                            showsApprovalPulse: workspace.agentTasks.records.contains(where: { $0.approval != nil }),
                            bounceValue: workspace.agentTasks.records.filter { $0.status == .completed }.count,
                            action: { tasksPresented = true }
                        )
                    }

                    if hasPluginItem {
                        collapsibleItem(index: 4, totalCount: extraItemCount) {
                            DesktopToolbarIconButton(
                                systemName: workspace.plugins.inspectorSnapshots.first?.symbol
                                    ?? workspace.plugins.activeInspectorCustomViews.first?.symbol
                                    ?? "puzzlepiece.extension",
                                help: "插件右侧栏卡片",
                                accessibilityLabel: "插件右侧栏卡片",
                                isActive: pluginInspectorPresented,
                                action: { pluginInspectorPresented.toggle() }
                            )
                            .popover(isPresented: $pluginInspectorPresented, arrowEdge: .bottom) {
                                DesktopPluginInspectorPopoverView(
                                    workspace: workspace,
                                    onFocusComposer: onFocusComposer,
                                    onDismiss: { pluginInspectorPresented = false }
                                )
                            }
                        }
                    }
                }
                .frame(width: max(0, effectiveWidth - 74), height: transform.baseHeight, alignment: .trailing)
                .clipped()
                .allowsHitTesting(extensionProgress > 0.65)

                Spacer(minLength: 0)

                DesktopToolbarIconButton(
                    systemName: "sidebar.right",
                    help: inspectorVisible ? "隐藏右侧面板" : "显示右侧面板（窗口足够宽时常驻）",
                    accessibilityLabel: "右侧面板",
                    action: onToggleInspector
                )
                .background(
                    DesktopToolbarSubframeProbe(
                        identifier: "amber.toolbar.inspectorToggle",
                        toolTip: inspectorVisible ? "隐藏右侧面板" : "显示右侧面板（窗口足够宽时常驻）"
                    )
                )
                .padding(.trailing, 4)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: effectiveWidth, height: transform.baseHeight)
        .background {
            ZStack {
                capsuleShape
                    .fill(
                        LinearGradient(
                            colors: [
                                DesktopTheme.card.opacity(0.97),
                                DesktopTheme.paper.opacity(0.93)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                if transform.specularOpacity > 0.01 {
                    capsuleShape
                        .fill(
                            RadialGradient(
                                colors: [
                                    DesktopTheme.honeySoft.opacity(0.90),
                                    DesktopTheme.honeySoft.opacity(0.25),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: effectiveWidth * 0.55
                            )
                        )
                        .opacity(transform.specularOpacity)
                }
                capsuleShape
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesktopTheme.honeyEdge.opacity(0.35 + 0.65 * transform.specularOpacity),
                                DesktopTheme.hairlineStrong,
                                DesktopTheme.honeyEdge.opacity(0.25 + 0.55 * transform.specularOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0 + 0.5 * transform.specularOpacity
                    )
            }
            .scaleEffect(x: 1.0, y: isChat ? transform.scaleY : 1.0, anchor: .center)
            .shadow(color: .black.opacity(0.045), radius: 4, y: 1.5)
        }
        .background(
            DesktopToolbarSubframeProbe(
                identifier: "amber.toolbar.liquidCapsule",
                toolTip: nil
            )
        )
    }

    @ViewBuilder
    private func collapsibleItem<Content: View>(
        index: Int,
        totalCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let itemTransform = DesktopLiquidMotion.toolbarItemTransform(
            index: index,
            totalCount: totalCount,
            extensionProgress: extensionProgress,
            reduceMotion: reduceMotion
        )
        content()
            .scaleEffect(itemTransform.scale)
            .offset(x: itemTransform.offsetX)
            .opacity(itemTransform.opacity)
    }
}

struct DesktopToolbarIconButton: View {
    let systemName: String
    let help: String
    let accessibilityLabel: String
    var disabled = false
    var isActive = false
    var showsApprovalPulse = false
    var bounceValue: Int? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if hovering || isActive {
                    Circle()
                        .fill(DesktopTheme.hover)
                        .frame(width: 26, height: 26)
                }
                if let bounceValue {
                    Image(systemName: systemName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.ink)
                        .symbolEffect(.bounce, value: bounceValue)
                        .overlay(alignment: .topTrailing) {
                            if showsApprovalPulse {
                                DesktopPulse().offset(x: 4, y: -3)
                            }
                        }
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.ink)
                }
            }
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1.0)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Pass-through AppKit view probe that exposes the exact window-space geometry and tooltip of toolbar sub-elements
/// without intercepting pointer events (`hitTest` returns `nil`).
struct DesktopToolbarSubframeProbe: NSViewRepresentable {
    let identifier: String
    let toolTip: String?

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.toolTip = toolTip
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
        nsView.toolTip = toolTip
    }
}
