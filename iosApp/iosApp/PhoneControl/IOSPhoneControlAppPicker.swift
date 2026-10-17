import SwiftUI

struct IOSPhoneControlAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    let controller: IOSPhoneControlController
    @State private var query = ""
    @State private var reload = 0
    @State private var errorMessage: String?
    @State private var addingID: String?

    private var matches: [PhoneControlInstalledApp] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.installedApplications.filter {
            search.isEmpty || $0.name.localizedStandardContains(search)
                || $0.bundleID.localizedStandardContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if controller.isLoadingApplications {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取本机应用…")
                    }
                    .accessibilityIdentifier("phoneAppsLoading")
                } else if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage).foregroundStyle(AmberTheme.accentRed)
                        Button("重新读取") { reload += 1 }
                    }
                } else if matches.isEmpty {
                    Text(query.isEmpty ? "未读取到可添加的应用" : "没有匹配的 App，试试英文名称或 Bundle ID")
                        .foregroundStyle(.secondary)
                }
                if !controller.isLoadingApplications && errorMessage == nil && !matches.isEmpty {
                    Section {
                        ForEach(matches) { app in
                            applicationRow(app)
                        }
                    } footer: {
                        Text("点击添加，可一次选择多个 App。部分应用可能显示英文名称。")
                    }
                }
            }
            .navigationTitle("选择本机 App")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "名称或 Bundle ID")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(AmberTheme.accent)
            .task(id: reload) {
                errorMessage = nil
                do { _ = try await controller.loadInstalledApplications() }
                catch is CancellationError { }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private func applicationRow(_ app: PhoneControlInstalledApp) -> some View {
        let selected = controller.selectedBundleIDs.contains(app.bundleID)
        Group {
            if selected {
                applicationLabel(app, selected: true)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button {
                    addingID = app.bundleID
                    Task {
                        defer { addingID = nil }
                        do { try await controller.addInstalledApplication(bundleID: app.bundleID) }
                        catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    applicationLabel(app, selected: false)
                }
                .buttonStyle(.plain)
                .disabled(addingID != nil)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name)，\(selected ? "已添加" : "添加")")
        .accessibilityIdentifier("phoneApp.\(app.bundleID)")
    }

    private func applicationLabel(_ app: PhoneControlInstalledApp, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: app.name).font(.body).foregroundStyle(Color.primary)
                Text(verbatim: app.bundleID)
                    .font(.caption.monospaced()).foregroundStyle(Color.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if addingID == app.bundleID {
                ProgressView().frame(width: 24, height: 24)
            } else {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
