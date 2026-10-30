import Foundation
@preconcurrency import Shared

@MainActor final class DesktopKMPModelCatalog: DesktopModelCatalog {
    func models(for configuration: DesktopProviderConfiguration, apiKey: String) async throws -> [DesktopCatalogModel] {
        do {
            if configuration.authMode == .codexOAuth {
                let models = try await IOSCodexOAuthClient(providerId: configuration.id.uuidString.lowercased()).fetchCodexModelsOrThrow()
                return models.map { DesktopCatalogModel(modelID: $0.modelId, name: $0.displayName) }
            }
            if configuration.authMode == .grokOAuth {
                let models = try await IOSGrokOAuthClients.shared(providerId: configuration.id.uuidString.lowercased()).fetchGrokModelsOrThrow()
                return models.map { DesktopCatalogModel(modelID: $0.modelId, name: $0.displayName) }
            }
            let bridge = DesktopProviderBridge.shared
            let json: String
            if configuration.kind == .gemini {
                let setting = try bridge.configurationWithAuth(kind: configuration.kind.rawValue,
                    id: configuration.id.uuidString, name: configuration.name, baseUrl: configuration.baseURL,
                    apiKey: apiKey, authMode: configuration.authMode.rawValue)
                guard let google = setting as? ProviderSetting.Google else { throw DesktopRuntimeError.message("Gemini 配置不匹配。") }
                json = bridge.catalogJSON(models: try await IOSGeminiClient(provider: google).listModelsOrThrow())
            } else {
                json = try await bridge.listModelsOrThrow(kind: configuration.kind.rawValue,
                    id: configuration.id.uuidString, name: configuration.name, baseUrl: configuration.baseURL, apiKey: apiKey,
                    authMode: configuration.authMode.rawValue)
            }
            return try DesktopJSON.decode([DesktopCatalogModel].self, from: json)
        } catch is CancellationError { throw CancellationError() }
        catch { throw DesktopRuntimeError.message("获取模型失败，请核对协议、地址、凭证与网络。") }
    }

    func testConnection(for configuration: DesktopProviderConfiguration, apiKey: String) async throws {
        let run = try DesktopKMPProvider().start(configuration: configuration, apiKey: apiKey,
            messages: [DesktopMessage(role: .user, text: "Reply OK.")], responseID: UUID())
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var received = false
                    for await _ in run.signals {
                        for event in run.drain() {
                            switch event {
                            case .snapshot(let text, _, _, _, _): received = received || !text.isEmpty
                            case .transcript(let messages): received = received || messages.contains { $0.role == .assistant && !$0.text.isEmpty }
                            case .complete:
                                guard received else { throw DesktopRuntimeError.message("服务商未返回文字内容。") }
                                return true
                            case .failed: throw DesktopRuntimeError.message("模型生成请求失败。")
                            case .cancelled: throw CancellationError()
                            }
                        }
                    }
                    throw DesktopRuntimeError.message("连接测试未收到终态。")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw DesktopRuntimeError.message("连接测试超时。")
                }
                defer { run.cancel(); group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: { run.cancel() }
    }
}

@MainActor final class DesktopMacCodexAuthorizer: DesktopCodexAuthorizer {
    func account(providerID: UUID) -> DesktopOAuthAccount? {
        IOSCodexAuthStore.load(providerId: providerID.uuidString.lowercased()).map {
            DesktopOAuthAccount(email: $0.email, plan: $0.planType)
        }
    }

    func requestCode(providerID: UUID) async throws -> DesktopDeviceAuthorization {
        let code = try await IOSCodexOAuthClient(providerId: providerID.uuidString.lowercased()).requestDeviceCode()
        guard let url = URL(string: code.verificationUrl), url.scheme == "https" else {
            throw DesktopRuntimeError.message("登录服务未返回有效地址。")
        }
        return DesktopDeviceAuthorization(verificationURL: url, userCode: code.userCode,
            deviceAuthID: code.deviceAuthId, intervalSeconds: code.intervalSeconds)
    }

    func poll(providerID: UUID, code: DesktopDeviceAuthorization) async throws -> DesktopOAuthAccount {
        let id = providerID.uuidString.lowercased()
        let authorization = IOSCodexDeviceAuthorization(verificationUrl: code.verificationURL.absoluteString,
            userCode: code.userCode, intervalSeconds: code.intervalSeconds, deviceAuthId: code.deviceAuthID)
        let tokens = try await IOSCodexOAuthClient(providerId: id).pollDeviceCode(authorization)
        guard IOSCodexAuthStore.load(providerId: id) == tokens else {
            throw DesktopRuntimeError.message("登录凭证未能写入钥匙串。")
        }
        return DesktopOAuthAccount(email: tokens.email, plan: tokens.planType)
    }

    func logout(providerID: UUID) async throws {
        let id = providerID.uuidString.lowercased()
        IOSCodexOAuthClient(providerId: id).logout()
        IOSAntigravityOAuthClients.logout(providerId: id)
        IOSGrokOAuthClients.logout(providerId: id)
        guard IOSCredentialSideTable.delete(key: IOSCodexAuthStore.credentialKey(providerId: id)),
              IOSCredentialSideTable.delete(key: IOSAntigravityAuthStore.credentialKey(providerId: id)),
              IOSCredentialSideTable.delete(key: IOSGrokOAuthAuthStore.credentialKey(providerId: id)),
              IOSCredentialSideTable.delete(key: IOSGrokOAuthAuthStore.backupKey(providerId: id)),
              IOSCredentialSideTable.delete(key: IOSGrokWebAuthStore.credentialKey(providerId: id)) else {
            throw DesktopRuntimeError.message("无法删除登录凭证，请解锁钥匙串后重试。")
        }
    }
}
