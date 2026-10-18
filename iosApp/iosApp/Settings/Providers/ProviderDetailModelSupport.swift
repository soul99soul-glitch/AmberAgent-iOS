import SwiftUI
import Shared

func providerModelIDLooksLikeImage(_ modelId: String) -> Bool {
    let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "gpt-image" || IOSCodexModelCatalog.isImageModelID(normalized)
}

extension ProviderDetailView {
    func displayName(for model: Model) -> String {
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.modelId : name
    }

    func modelDefaultSelection(for model: Model) -> String? {
        if model.type == ModelType.chat, model.id == currentModel?.id {
            return "聊天默认"
        }
        if model.type == ModelType.image, model.id == imageGenerationModel?.id {
            return "生图默认"
        }
        return nil
    }

    func modelTypeTitle(for model: Model) -> String {
        if model.type == ModelType.image { return "生图" }
        if model.type == ModelType.embedding { return "嵌入" }
        return "聊天"
    }

    func modelSystemImage(for model: Model) -> String {
        if model.type == ModelType.image { return "photo" }
        if model.type == ModelType.embedding { return "function" }
        return "cpu"
    }

    func modelSummary(_ model: Model) -> String {
        var parts: [String] = [model.modelId]
        if let context = intValue(model.contextWindowTokens) {
            parts.append("\(context) ctx")
        }
        if !model.customHeaders.isEmpty {
            parts.append("\(model.customHeaders.count) headers")
        }
        return parts.joined(separator: " · ")
    }

    func apiKey(of provider: ProviderSetting?) -> String {
        if let openAI = provider as? ProviderSetting.OpenAI { return openAI.apiKey }
        if let claude = provider as? ProviderSetting.Claude { return claude.apiKey }
        if let google = provider as? ProviderSetting.Google { return google.apiKey }
        return ""
    }

    func hasConnectionCredential(_ provider: ProviderSetting) -> Bool {
        if IOSCodexProviderResolver.isCodexProvider(provider) {
            return IOSCodexProviderResolver.isSignedIn(provider)
        }
        if IOSGrokWebProviderResolver.isGrokWebProvider(provider) {
            return IOSGrokWebProviderResolver.isSignedIn(provider)
        }
        if let google = provider as? ProviderSetting.Google,
           IOSGeminiProviderResolver.isAntigravityOAuth(google) {
            return IOSGeminiProviderResolver.isSignedIn(provider)
        }
        return !apiKey(of: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func connectionCredentialIssue(_ provider: ProviderSetting) -> ChatConfigurationIssue {
        if IOSCodexProviderResolver.isCodexProvider(provider) { return .codexNotSignedIn }
        if IOSGrokWebProviderResolver.isGrokWebProvider(provider) { return .grokNotSignedIn }
        if let google = provider as? ProviderSetting.Google,
           IOSGeminiProviderResolver.isAntigravityOAuth(google) { return .geminiNotSignedIn }
        return .missingAPIKey
    }

    func baseURL(of provider: ProviderSetting) -> String {
        if let openAI = provider as? ProviderSetting.OpenAI { return openAI.baseUrl }
        if let claude = provider as? ProviderSetting.Claude { return claude.baseUrl }
        if let google = provider as? ProviderSetting.Google { return google.baseUrl }
        return ""
    }

    func normalizedBaseURL(_ value: String) -> String {
        var baseURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        return baseURL
    }

    func isValidHTTPBaseURL(_ value: String) -> Bool {
        IOSProviderEndpointPolicy.isValidBaseURL(value)
    }

    func intValue(_ value: KotlinInt?) -> Int? {
        value.map { Int(truncating: $0) }
    }
}

enum ProviderDetailTab: String, CaseIterable, Identifiable {
    case config
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .config: "配置"
        case .models: "模型"
        }
    }
}

enum ProviderConnectionStatus: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        self == .testing
    }

    var message: String? {
        switch self {
        case .idle, .testing:
            nil
        case .success(let message), .failure(let message):
            message
        }
    }
}

enum ProviderModelFetchState: Equatable {
    case idle
    case loading
    case success(String)
    case failure(String)

    var isLoading: Bool {
        self == .loading
    }

    var message: String? {
        switch self {
        case .idle, .loading:
            nil
        case .success(let message), .failure(let message):
            message
        }
    }
}

enum ProviderDetailAlert: Identifiable {
    case saved
    case invalidBaseURL
    case requestHeadersSaveFailed
    case configurationSaveFailed(String)
    case protocolSwitchFailed
    case unsupportedProtocol
    case modelRequired
    case chatModelRequired
    case currentModelSet(String)
    case currentModelDeleted
    case legacyKeyImported
    case deleteProvider(String)
    case providerDeleteFailed

    var id: String {
        switch self {
        case .saved: "saved"
        case .invalidBaseURL: "invalid-base-url"
        case .requestHeadersSaveFailed: "request-headers-save-failed"
        case .configurationSaveFailed: "configuration-save-failed"
        case .protocolSwitchFailed: "protocol-switch-failed"
        case .unsupportedProtocol: "unsupported-protocol"
        case .modelRequired: "model-required"
        case .chatModelRequired: "chat-model-required"
        case .currentModelSet(let model): "current-model-\(model)"
        case .currentModelDeleted: "current-model-deleted"
        case .legacyKeyImported: "legacy-key-imported"
        case .deleteProvider: "delete-provider"
        case .providerDeleteFailed: "provider-delete-failed"
        }
    }

    var title: String {
        switch self {
        case .saved:
            IOSAppLocalization.string("已保存", defaultValue: "已保存")
        case .invalidBaseURL:
            IOSAppLocalization.string("API 地址无效", defaultValue: "API 地址无效")
        case .requestHeadersSaveFailed:
            IOSAppLocalization.string("请求头保存失败", defaultValue: "请求头保存失败")
        case .configurationSaveFailed:
            IOSAppLocalization.string("服务商保存失败", defaultValue: "服务商保存失败")
        case .protocolSwitchFailed:
            IOSAppLocalization.string("协议切换失败", defaultValue: "协议切换失败")
        case .unsupportedProtocol:
            IOSAppLocalization.string("暂不支持", defaultValue: "暂不支持")
        case .modelRequired:
            IOSAppLocalization.string("需要 Model ID", defaultValue: "需要 Model ID")
        case .chatModelRequired:
            IOSAppLocalization.string("需要聊天模型", defaultValue: "需要聊天模型")
        case .currentModelSet:
            IOSAppLocalization.string("已设为当前", defaultValue: "已设为当前")
        case .currentModelDeleted:
            IOSAppLocalization.string("当前模型已删除", defaultValue: "当前模型已删除")
        case .legacyKeyImported:
            IOSAppLocalization.string("已导入", defaultValue: "已导入")
        case .deleteProvider:
            IOSAppLocalization.string("删除服务商？", defaultValue: "删除服务商？")
        case .providerDeleteFailed:
            IOSAppLocalization.string("无法删除服务商", defaultValue: "无法删除服务商")
        }
    }

    var message: String {
        switch self {
        case .saved:
            IOSAppLocalization.string(
                "服务商配置已写入当前设置。",
                defaultValue: "服务商配置已写入当前设置。"
            )
        case .invalidBaseURL:
            IOSAppLocalization.string(
                "请输入 HTTPS 地址，或使用 http://IP:端口形式的 API 地址。",
                defaultValue: "请输入 HTTPS 地址，或使用 http://IP:端口形式的 API 地址。"
            )
        case .requestHeadersSaveFailed:
            IOSAppLocalization.string(
                "自定义请求头未能安全保存，请重试。",
                defaultValue: "自定义请求头未能安全保存，请重试。"
            )
        case .configurationSaveFailed(let message):
            message
        case .protocolSwitchFailed:
            IOSAppLocalization.string(
                "没有找到可切换的服务商配置。",
                defaultValue: "没有找到可切换的服务商配置。"
            )
        case .unsupportedProtocol:
            IOSAppLocalization.string(
                "这个 Provider 类型的 iOS 聊天执行器尚未移植。",
                defaultValue: "这个 Provider 类型的 iOS 聊天执行器尚未移植。"
            )
        case .modelRequired:
            IOSAppLocalization.string(
                "请填写服务商文档中的 Model ID。",
                defaultValue: "请填写服务商文档中的 Model ID。"
            )
        case .chatModelRequired:
            IOSAppLocalization.string(
                "当前聊天模型不能改成生图或嵌入模型；请先添加或保留一个聊天模型。",
                defaultValue: "当前聊天模型不能改成生图或嵌入模型；请先添加或保留一个聊天模型。"
            )
        case .currentModelSet(let model):
            IOSAppLocalization.formatted(
                "新的聊天会默认使用 %@。",
                defaultValue: "新的聊天会默认使用 %@。",
                arguments: [model]
            )
        case .currentModelDeleted:
            IOSAppLocalization.string(
                "你删除的是当前聊天模型，请在模型页重新选择一个当前模型。",
                defaultValue: "你删除的是当前聊天模型，请在模型页重新选择一个当前模型。"
            )
        case .legacyKeyImported:
            IOSAppLocalization.string(
                "旧 API Key 已写入当前服务商。",
                defaultValue: "旧 API Key 已写入当前服务商。"
            )
        case .deleteProvider(let name):
            IOSAppLocalization.formatted(
                "%@ 的配置、模型和 API Key 将被删除，此操作无法撤销。",
                defaultValue: "%@ 的配置、模型和 API Key 将被删除，此操作无法撤销。",
                arguments: [name]
            )
        case .providerDeleteFailed:
            IOSAppLocalization.string(
                "内置服务商不能删除；当前服务商没有可切换的备用聊天模型时也不能删除。",
                defaultValue: "内置服务商不能删除；当前服务商没有可切换的备用聊天模型时也不能删除。"
            )
        }
    }
}

struct ProviderModelDraft: Identifiable {
    let id = UUID()
    var modelUuid: String?
    var modelId: String
    var displayName: String
    var contextWindowText: String
    var type: ModelType
    var inputModalities: [Modality]
    var headers: [ProviderHeaderDraft]

    init() {
        self.modelUuid = nil
        self.modelId = ""
        self.displayName = ""
        self.contextWindowText = ""
        self.type = .chat
        self.inputModalities = [.text]
        self.headers = []
    }

    init(model: Model) {
        self.modelUuid = model.id.description()
        self.modelId = model.modelId
        self.displayName = model.displayName
        if let context = model.contextWindowTokens {
            self.contextWindowText = "\(Int(truncating: context))"
        } else {
            self.contextWindowText = ""
        }
        self.type = model.type
        self.inputModalities = model.inputModalities.isEmpty
            ? (ModelRegistry.shared.MODEL_INPUT_MODALITIES.getData(modelId: model.modelId) as? [Modality] ?? [.text])
            : model.inputModalities
        self.headers = model.customHeaders.map { ProviderHeaderDraft(name: $0.name, value: $0.value) }
    }

    var contextWindowTokens: Int? {
        let trimmed = contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed.replacingOccurrences(of: ",", with: ""))
    }
}

struct ProviderHeaderDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String
}

