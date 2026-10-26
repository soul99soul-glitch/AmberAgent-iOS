import SwiftUI

struct DesktopStorageUsageView: View {
    let sources: [DesktopStorageUsage.Source]
    var conversationCount: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: DesktopStorageUsage.Snapshot?
    @State private var isMeasuring = false
    @State private var error: String?
    @State private var scan: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("存储用量").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let snapshot {
                HStack(spacing: 32) {
                    metric("已统计用量", value: bytes(snapshot.totalBytes))
                    metric("磁盘文件", value: "\(snapshot.totalFileCount)")
                    if let conversationCount { metric("会话", value: "\(conversationCount)") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(snapshot.areas, id: \.id) { area in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(area.title).font(.system(size: 13, weight: .medium))
                                    if let note = area.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(area.byteCount.map(bytes) ?? "未统计").monospacedDigit()
                                    if let count = area.fileCount { Text("\(count) 个文件").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(.vertical, 13)
                            Divider()
                        }
                    }
                }
                Text("统计时间：\(snapshot.scannedAt.formatted(date: .numeric, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isMeasuring && error == nil {
                ContentUnavailableView("尚未统计", systemImage: "internaldrive", description: Text("刷新可读取本机目录的当前用量。"))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isMeasuring { ProgressView().controlSize(.small); Text("正在统计本机目录…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("刷新统计") { refresh() }.disabled(isMeasuring)
            }
            Text("未统计项不计入合计。备份与恢复可在通用设置中打开；会话文件可在工作台文件栏中管理。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 610, height: 550)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .task { if snapshot == nil { refresh() } }
        .onDisappear { scan?.cancel() }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesktopTheme.muted(colorScheme))
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func refresh() {
        guard !isMeasuring else { return }
        isMeasuring = true; error = nil
        scan = Task {
            defer { isMeasuring = false; scan = nil }
            do {
                let measured = try await DesktopStorageUsage.measure(sources)
                try Task.checkCancellation()
                snapshot = measured
            } catch is CancellationError {
            } catch { self.error = "读取存储用量失败，请检查目录权限后重试。" }
        }
    }
}
