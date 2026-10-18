import Foundation
import SwiftUI
import WebKit

@MainActor
struct WebMountSiteMemorySheet: View {
    let hosts: [String]
    let registry: IOSWebMountRegistry
    let onClose: () -> Void

    @State private var selectedHost: String
    @State private var entries: [IOSWebMountSiteMemoryEntry] = []
    @State private var showsClearConfirmation = false

    init(host: String, registry: IOSWebMountRegistry, onClose: @escaping () -> Void) {
        self.init(hosts: [host], selectedHost: host, registry: registry, onClose: onClose)
    }

    init(
        hosts: [String],
        selectedHost: String?,
        registry: IOSWebMountRegistry,
        onClose: @escaping () -> Void
    ) {
        let normalizedHosts = hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, host in
                if !result.contains(host) { result.append(host) }
            }
        let requestedHost = selectedHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.hosts = normalizedHosts
        self.registry = registry
        self.onClose = onClose
        _selectedHost = State(initialValue: normalizedHosts.first(where: { $0 == requestedHost }) ?? normalizedHosts.first ?? "")
    }

    private var host: String { selectedHost }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Agent 提议的站点经验经手动批准或高风险自动批准后保存在本机，供后续任务参考。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    AmberSectionLabel(text: "站点记忆")
                    if hosts.count > 1 {
                        HStack {
                            Text("站点域名")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                            Spacer(minLength: 8)
                            Picker("站点域名", selection: $selectedHost) {
                                ForEach(hosts, id: \.self) { host in
                                    Text(host).tag(host)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("webmount.siteMemory.hostPicker")
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    } else {
                        Text(host)
                            .font(.caption.monospaced())
                            .foregroundStyle(AmberTheme.muted)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    if entries.isEmpty {
                        AmberFormGroup {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("暂无站点记忆")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(AmberTheme.foreground)
                                Text("Agent 提交记忆提案，经手动批准或高风险自动批准后会显示在这里。")
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                        }
                    } else {
                        AmberFormGroup {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                WebMountSiteMemoryEntryRow(entry: entry) {
                                    registry.deleteSiteMemoryEntry(host: host, id: entry.id)
                                    reloadEntries()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)

                                if index < entries.count - 1 {
                                    Divider()
                                        .overlay(AmberTheme.borderSoft)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(AmberTheme.surface2)
            .navigationTitle("站点记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AmberTheme.surface2, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier("webmount.siteMemory.clear")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", systemImage: "xmark", action: onClose)
                }
            }
            .confirmationDialog(
                "清空站点记忆？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空记忆", role: .destructive) {
                    registry.clearSiteMemory(host: host)
                    reloadEntries()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除 \(host) 的全部站点记忆。")
            }
        }
        .task(id: selectedHost) { reloadEntries() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("webmount.siteMemory.root")
    }

    private func reloadEntries() {
        guard !host.isEmpty else {
            entries = []
            return
        }
        entries = registry.siteMemory(host: host)
    }
}

private struct WebMountSiteMemoryEntryRow: View {
    let entry: IOSWebMountSiteMemoryEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(kindLabel, systemImage: kindImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除\(kindLabel)：\(entry.name)")
                .accessibilityIdentifier("webmount.siteMemory.delete.\(entry.id)")
            }

            Text(entry.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let urlPattern = entry.urlPattern?.nilIfBlank {
                memoryValue(label: "URL 模式", value: urlPattern, monospaced: true)
            }
            if let locatorJSON = entry.locatorJSON?.nilIfBlank {
                memoryValue(label: "Locator", value: locatorJSON, monospaced: true)
            }
            if let detail = entry.detail.nilIfBlank {
                memoryValue(label: "说明", value: detail, monospaced: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("来源：\(entry.source.rawValue == "user" ? "用户" : "Agent")")
                Text("更新于：\(Date(timeIntervalSince1970: Double(entry.updatedAtMillis) / 1_000).formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webmount.siteMemory.entry.\(entry.id)")
    }

    private var kindLabel: String {
        switch entry.kind.rawValue {
        case "pages": "页面"
        case "actions": "操作"
        case "pitfalls": "注意事项"
        case "cannot_do": "无法执行"
        default: entry.kind.rawValue
        }
    }

    private var kindImage: String {
        switch entry.kind.rawValue {
        case "pages": "doc.text"
        case "actions": "cursorarrow.click"
        case "pitfalls": "exclamationmark.triangle"
        case "cannot_do": "xmark.circle"
        default: "text.alignleft"
        }
    }

    private func memoryValue(label: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
