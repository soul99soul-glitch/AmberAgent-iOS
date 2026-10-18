import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct WorkspaceMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AmberTheme.foreground)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }
}

struct WorkspaceEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }
}

struct WorkspaceFileRow: View {
    let record: IOSWorkspaceFileRecord
    let action: () -> Void

    var body: some View {
        AmberFormRow(
            systemImage: statusIcon,
            iconColor: statusColor,
            title: record.displayName,
            subtitle: "\(record.byteSummary) · \(record.status.title) · /workspace/\(record.workspacePath)",
            trailing: WorkspaceDateFormat.short(record.updatedAtMillis),
            showsChevron: true,
            action: action
        )
    }

    private var statusIcon: String {
        switch record.status {
        case .ready: "doc.text"
        case .missing: "doc.badge.exclamationmark"
        case .parseFailed: "exclamationmark.triangle"
        case .unsupported: "nosign"
        case .tooLarge: "externaldrive.badge.exclamationmark"
        case .needsReauthorization: "lock.open"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .ready: AmberTheme.accentIndigo
        case .unsupported, .needsReauthorization: AmberTheme.accentAmber
        case .missing, .parseFailed, .tooLarge: AmberTheme.accentRed
        }
    }
}

struct WorkspaceArtifactRow: View {
    let record: IOSWorkspaceArtifactRecord
    let action: () -> Void

    var body: some View {
        AmberFormRow(
            systemImage: "sparkles.rectangle.stack",
            iconColor: AmberTheme.accentAmber,
            title: record.title,
            subtitle: "\(record.type.title) · \(DocumentAccessStore.formatBytes(record.contentBytes))",
            trailing: WorkspaceDateFormat.short(record.updatedAtMillis),
            showsChevron: true,
            action: action
        )
    }
}

struct WorkspaceFileDetailSheet: View {
    let record: IOSWorkspaceFileRecord
    @Bindable var store: IOSWorkspaceStore
    let onReparse: () -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkspaceDetailHeader(
                        systemImage: "doc.text",
                        title: record.displayName,
                        subtitle: "/workspace/\(record.workspacePath)"
                    )

                    WorkspaceInfoGrid(rows: [
                        ("状态", record.status.title),
                        ("大小", record.byteSummary),
                        ("类型", record.mimeType),
                        ("字符", "\(record.characterCount)"),
                        ("来源", record.source),
                        ("更新", WorkspaceDateFormat.long(record.updatedAtMillis))
                    ])

                    if !record.statusMessage.isEmpty {
                        WorkspaceStatusBanner(status: record.status, message: record.statusMessage)
                    }

                    WorkspacePreviewBlock(text: record.preview, emptyText: previewEmptyText)
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        onReparse()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新解析")

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("移除文件")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var previewEmptyText: String {
        let key: String
        switch record.status {
        case .ready:
            key = "没有可预览文本。"
        case .missing:
            key = "文件副本丢失，请重新导入。"
        case .unsupported:
            key = "此格式暂不支持文本预览。"
        case .tooLarge:
            key = "文件超过本地解析上限。"
        case .needsReauthorization:
            key = "需要从 Files 重新选择文件。"
        case .parseFailed:
            key = "解析失败，可尝试重新解析。"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

struct WorkspaceArtifactDetailSheet: View {
    let record: IOSWorkspaceArtifactRecord
    @Bindable var store: IOSWorkspaceStore
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var content: String {
        (try? store.artifactContent(id: record.id)) ?? IOSAppLocalization.string(
            "Artifact 内容丢失或读取失败。",
            defaultValue: "Artifact 内容丢失或读取失败。"
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkspaceDetailHeader(
                        systemImage: "sparkles.rectangle.stack",
                        title: record.title,
                        subtitle: record.type.title
                    )
                    WorkspaceInfoGrid(rows: [
                        ("大小", DocumentAccessStore.formatBytes(record.contentBytes)),
                        ("来源", record.sourceKind),
                        ("创建", WorkspaceDateFormat.long(record.createdAtMillis)),
                        ("更新", WorkspaceDateFormat.long(record.updatedAtMillis))
                    ])
                    WorkspacePreviewBlock(
                        text: content,
                        emptyText: IOSAppLocalization.string(
                            "Artifact 内容为空。",
                            defaultValue: "Artifact 内容为空。"
                        )
                    )
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除 Artifact")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct WorkspaceDetailHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 42, height: 42)
                .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(3)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct WorkspaceInfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top) {
                    Text(verbatim: IOSAppLocalization.string(row.0, defaultValue: row.0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(width: 56, alignment: .leading)
                    Text(row.1)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)
                if index < rows.count - 1 {
                    Divider().overlay(AmberTheme.borderSoft)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
    }
}

private struct WorkspaceStatusBanner: View {
    let status: IOSWorkspaceFileStatus
    let message: String

    var body: some View {
        Label(message, systemImage: status == .ready ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(status == .ready ? AmberTheme.accentGreen : AmberTheme.accentAmber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((status == .ready ? AmberTheme.accentGreen : AmberTheme.accentAmber).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WorkspacePreviewBlock: View {
    let text: String
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: IOSAppLocalization.string("预览", defaultValue: "预览"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .textCase(.uppercase)
            Text(text.isEmpty ? emptyText : text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(text.isEmpty ? AmberTheme.muted : AmberTheme.foreground2)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        }
    }
}

private enum WorkspaceDateFormat {
    static func short(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func long(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = DateFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
