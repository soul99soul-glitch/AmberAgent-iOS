import SwiftUI

struct DesktopSearchSettingsView: View {
    let settings: DesktopSearchSettings
    @Environment(\.dismiss) private var dismiss
    @State private var service: DesktopSearchService
    @State private var resultCount: Int
    @State private var apiKey = ""
    @State private var error: String?

    init(settings: DesktopSearchSettings) {
        self.settings = settings
        _service = State(initialValue: settings.service)
        _resultCount = State(initialValue: settings.resultCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("联网搜索").font(DesktopTheme.serif(size: 22, weight: .semibold))
            Text("聊天工具与 Recipe 共用此配置；搜索结果会回到发起任务的会话。")
                .foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("搜索服务", selection: $service) {
                    ForEach(DesktopSearchService.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("结果数量") {
                    HStack(spacing: 6) {
                        TextField("", value: $resultCount, format: .number)
                            .textFieldStyle(.desktop)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .onChange(of: resultCount) { _, value in
                                let clamped = min(DesktopSearchSettings.resultLimit, max(1, value))
                                if clamped != value { resultCount = clamped }
                            }
                        Stepper("", value: $resultCount, in: 1...DesktopSearchSettings.resultLimit).labelsHidden()
                        Text("1–\(DesktopSearchSettings.resultLimit)").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                }
                if service != .free { SecureField("API Key", text: $apiKey).textFieldStyle(.desktop) }
                Text(service == .free ? "免费聚合源可能受到反爬限制；可切换到你已有凭证的搜索服务。" : "凭证保存在本机钥匙串，备份与导出不包含此凭证。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Text(error).foregroundStyle(DesktopTheme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try settings.save(service: service, resultCount: resultCount, apiKey: apiKey); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500)
        .task { loadKey() }
        .onChange(of: service) { _, _ in loadKey() }
    }
    private func loadKey() {
        do { apiKey = try settings.apiKey(for: service); error = nil }
        catch { apiKey = ""; self.error = error.localizedDescription }
    }
}
