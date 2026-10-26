import SwiftUI
@preconcurrency import Shared

@MainActor
extension IOSSharedSettingsStore {
    func searchProviderSupportsAPIKey(serviceId: String) -> Bool {
        guard let service = snapshot.searchServices.first(where: { $0.id.description() == serviceId }) else {
            return false
        }
        return SearchProviderType(service: service)?.requiresAPIKey == true
    }

    @discardableResult
    func updateSearchProviderApiKey(serviceId: String, apiKey: String) -> Bool {
        let replacement = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, replacement != IOSCredentialRedactor.mask,
              searchProviderSupportsAPIKey(serviceId: serviceId) else {
            return false
        }
        let updated = IosSettingsMutations.shared.updateSearchServiceApiKey(
            settings: snapshot,
            id: serviceId,
            apiKey: replacement
        )
        return restoreSnapshot(updated)
    }
}

struct IOSSearchProviderCredentialEditor: View {
    let sharedSettings: IOSSharedSettingsStore
    let provider: IOSConfiguredSearchProvider

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AmberSectionLabel(text: "\(provider.name)")
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("新的 API Key")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                            SecureField("输入新的 API Key", text: $apiKey)
                                .font(.body.monospaced())
                                .foregroundStyle(AmberTheme.foreground)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("新的 API Key")
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    Text("输入新的 API Key 后保存。留空或关闭此页面不会更改现有凭据。")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.accentRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(AmberTheme.background)
            .navigationTitle("更新 API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let replacement = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !replacement.isEmpty && replacement != IOSCredentialRedactor.mask
    }

    private func save() {
        if sharedSettings.updateSearchProviderApiKey(serviceId: provider.id, apiKey: apiKey) {
            dismiss()
        } else {
            errorMessage = sharedSettings.credentialPersistenceError ?? "该服务已不存在或无法更新 API Key，请关闭页面后重试。"
        }
    }
}
