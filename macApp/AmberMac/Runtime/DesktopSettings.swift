import Foundation
import Observation
import Security

/// Which key combination sends; the other plain/Shift Return inserts a newline.
enum DesktopSendShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case commandReturn, returnKey, shiftReturn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .commandReturn: "⌘Return 发送"
        case .returnKey: "Return 发送"
        case .shiftReturn: "⇧Return 发送"
        }
    }
    var sendLabel: String {
        switch self {
        case .commandReturn: "⌘Return"
        case .returnKey: "Return"
        case .shiftReturn: "⇧Return"
        }
    }
    var newlineLabel: String { self == .returnKey ? "⇧Return" : "Return" }
}

enum DesktopMessageFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "系统"
        case .serif: "衬线"
        case .mono: "等宽"
        }
    }
}

protocol DesktopCredentialStore {
    func load(id: UUID) throws -> String
    func save(_ value: String, id: UUID) throws
    func delete(id: UUID) throws
}

struct DesktopKeychain: DesktopCredentialStore {
    private let service: String
    init(service: String = "app.amber.mac.providers") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func load(id: UUID) throws -> String {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }

    func save(_ value: String, id: UUID) throws {
        if value.isEmpty { try delete(id: id); return }
        if DesktopHistoryRedaction.isPlaceholderCredential(value) {
            throw DesktopRuntimeError.message("不能将脱敏占位符保存为凭据。")
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> DesktopRuntimeError {
        .message("无法访问钥匙串（\(status)），请解锁钥匙串后重试。")
    }
}

@MainActor @Observable
final class DesktopSettings {
    private static let persistedSettingsKey = "desktop.settings.v1"
    private static let recoverySettingsKey = "desktop.settings.recovery.v1"

    private(set) var providers: [DesktopProviderConfiguration]
    var selectedProviderID: UUID? { didSet { if !isInitializing { persist() } } }
    var systemPrompt: String { didSet { persist() } }
    var appearance: String { didSet { persist() } }
    var messageFontFamily: DesktopMessageFontFamily { didSet { persist() } }
    private var storedMessageFontSize: Double
    var messageFontSize: Double {
        get { storedMessageFontSize }
        set {
            let value = newValue.isFinite ? min(22, max(12, newValue)) : 14
            guard storedMessageFontSize != value else { return }
            storedMessageFontSize = value
            persist()
        }
    }
    var assistantName: String { didSet { persist() } }
    var userNickname: String { didSet { persist() } }
    var reasoningExpandedByDefault: Bool { didSet { persist() } }
    /// iOS「自动展开思考」: open while the model is thinking, fold softly once the answer starts.
    var autoExpandThinking: Bool { didSet { persist() } }
    var automaticallyFollowGeneration: Bool { didSet { persist() } }
    /// Tool calls stay in the conversation data either way; this only hides their cards in the transcript.
    var hidesToolCalls: Bool { didSet { persist() } }
    var sendShortcut: DesktopSendShortcut { didSet { persist() } }
    /// 长程工具任务的轮数上限；默认值足够跑满一小时以上的多步任务，可在设置里下调或再调高。
    private var storedAgentToolRoundLimit: Int
    var agentToolRoundLimit: Int {
        get { storedAgentToolRoundLimit }
        set {
            let value = DesktopAgentRunLimits.clampedRounds(newValue)
            guard storedAgentToolRoundLimit != value else { return }
            storedAgentToolRoundLimit = value
            persist()
        }
    }
    /// 单次工具任务的实际运行时长上限（分钟）；到点就停，不靠轮数估算。
    private var storedAgentRunMinutes: Int
    var agentRunMinutes: Int {
        get { storedAgentRunMinutes }
        set {
            let value = DesktopAgentRunLimits.clampedMinutes(newValue)
            guard storedAgentRunMinutes != value else { return }
            storedAgentRunMinutes = value
            persist()
        }
    }
    var notificationsEnabled: Bool { didSet { persist() } }
    var speechVoiceIdentifier: String { didSet { persist() } }
    private var storedSpeechRate: Double
    var speechRate: Double {
        get { storedSpeechRate }
        set {
            let value = newValue.isFinite ? min(0.6, max(0.2, newValue)) : 0.5
            guard storedSpeechRate != value else { return }
            storedSpeechRate = value
            persist()
        }
    }
    private(set) var auxiliaryModelIDs: [String: UUID]
    private(set) var settingsRecoveryMessage: String?
    private(set) var hasSettingsRecoveryCopy: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore
    @ObservationIgnored private var isInitializing = true

    private struct Record: Codable {
        var providers: [DesktopProviderConfiguration]
        var selectedProviderID: UUID?
        var systemPrompt: String
        var appearance: String
        var auxiliaryModelIDs: [String: UUID]?
        var messageFontFamily: DesktopMessageFontFamily?
        var messageFontSize: Double?
        var assistantName: String?
        var userNickname: String?
        var reasoningExpandedByDefault: Bool?
        var autoExpandThinking: Bool?
        var automaticallyFollowGeneration: Bool?
        var hidesToolCalls: Bool?
        var sendShortcut: DesktopSendShortcut?
        var notificationsEnabled: Bool?
        var speechVoiceIdentifier: String?
        var speechRate: Double?
        var agentToolRoundLimit: Int?
        var agentRunMinutes: Int?
    }

    init(defaults: UserDefaults = .standard, credentials: any DesktopCredentialStore = DesktopKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        let persistedData = defaults.data(forKey: Self.persistedSettingsKey)
        hasSettingsRecoveryCopy = defaults.data(forKey: Self.recoverySettingsKey) != nil
        let record = persistedData.flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        if let persistedData, record == nil {
            defaults.set(persistedData, forKey: Self.recoverySettingsKey)
            hasSettingsRecoveryCopy = true
            settingsRecoveryMessage = "设置文件无法读取，已保留恢复副本。当前使用默认设置；保存新设置后即可继续使用。"
        } else {
            settingsRecoveryMessage = nil
        }
        let initial = DesktopProviderConfiguration(name: "OpenAI", kind: .openAI,
            baseURL: "https://api.openai.com/v1", modelID: "")
        let loadedProviders = record?.providers ?? [initial]
        providers = loadedProviders
        selectedProviderID = record?.selectedProviderID ?? loadedProviders.first?.id
        systemPrompt = record?.systemPrompt ?? ""
        appearance = record?.appearance ?? "system"
        messageFontFamily = record?.messageFontFamily ?? .system
        storedMessageFontSize = min(22, max(12, record?.messageFontSize ?? 14))
        assistantName = record?.assistantName ?? "Amber"
        userNickname = record?.userNickname ?? "你"
        reasoningExpandedByDefault = record?.reasoningExpandedByDefault ?? false
        autoExpandThinking = record?.autoExpandThinking ?? true
        automaticallyFollowGeneration = record?.automaticallyFollowGeneration ?? true
        hidesToolCalls = record?.hidesToolCalls ?? false
        sendShortcut = record?.sendShortcut ?? .commandReturn
        storedAgentToolRoundLimit = DesktopAgentRunLimits.clampedRounds(record?.agentToolRoundLimit ?? DesktopAgentRunLimits.defaultRounds)
        storedAgentRunMinutes = DesktopAgentRunLimits.clampedMinutes(record?.agentRunMinutes ?? DesktopAgentRunLimits.defaultMinutes)
        notificationsEnabled = record?.notificationsEnabled ?? false
        speechVoiceIdentifier = record?.speechVoiceIdentifier ?? ""
        storedSpeechRate = min(0.6, max(0.2, record?.speechRate ?? 0.5))
        auxiliaryModelIDs = record?.auxiliaryModelIDs ?? [:]
        repairSelection()
        isInitializing = false
        // Also commits the one-time legacy single-model -> stable model UUID migration.
        if record != nil || persistedData == nil { persist() }
    }

    func unreadableSettingsRecoveryData() -> Data? {
        defaults.data(forKey: Self.recoverySettingsKey)
    }

    var selectedProvider: DesktopProviderConfiguration? {
        providers.first { $0.id == selectedProviderID }
    }

    var selectedModelID: UUID? {
        guard let model = selectedProvider?.selectedModel,
              !model.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return model.id
    }

    var selectedModelSupportedReasoningLevels: [DesktopReasoningLevel] {
        guard let provider = selectedProvider, let model = provider.selectedModel else { return [] }
        return DesktopThinkingPolicy.supportedLevels(for: model, provider: provider)
    }

    var selectedModelReasoning: DesktopReasoningLevel {
        guard let provider = selectedProvider, let model = provider.selectedModel else { return .off }
        let supported = DesktopThinkingPolicy.supportedLevels(for: model, provider: provider)
        return DesktopThinkingPolicy.coercedLevel(model.reasoning, supported: supported)
    }

    func setSelectedModelReasoning(_ level: DesktopReasoningLevel) {
        guard let providerID = selectedProviderID,
              let providerIndex = providers.firstIndex(where: { $0.id == providerID }),
              let model = providers[providerIndex].selectedModel,
              let modelIndex = providers[providerIndex].models.firstIndex(where: { $0.id == model.id }) else { return }
        let supported = DesktopThinkingPolicy.supportedLevels(for: model, provider: providers[providerIndex])
        let coerced = DesktopThinkingPolicy.coercedLevel(level, supported: supported)
        guard providers[providerIndex].models[modelIndex].reasoning != coerced else { return }
        providers[providerIndex].models[modelIndex].reasoning = coerced
        persist()
    }
    var assistantDisplayName: String {
        let name = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Amber" : name
    }
    var userDisplayName: String {
        let name = userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "你" : name
    }

    var modelSelections: [DesktopModelSelection] {
        providers.flatMap { provider in
            provider.models.filter { $0.enabled && !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { model in
                DesktopModelSelection(id: model.id, providerID: provider.id, providerName: provider.name,
                    modelName: model.displayName, modelID: model.modelID)
            }
        }
    }

    func selectModel(_ id: UUID) {
        guard let index = providers.firstIndex(where: { $0.models.contains(where: { $0.id == id && $0.enabled }) }) else { return }
        providers[index].selectedModelID = id
        if selectedProviderID != providers[index].id { selectedProviderID = providers[index].id }
        else { persist() }
    }

    func configuration(forModelID id: UUID) -> DesktopProviderConfiguration? {
        guard var provider = providers.first(where: { $0.models.contains(where: { $0.id == id && $0.enabled }) }) else { return nil }
        provider.selectedModelID = id
        return provider
    }

    func configuration(for task: DesktopAuxiliaryModelTask) -> DesktopProviderConfiguration? {
        configuredAuxiliaryModel(for: task) ?? selectedProvider
    }

    func configuredAuxiliaryModel(for task: DesktopAuxiliaryModelTask) -> DesktopProviderConfiguration? {
        auxiliaryModelIDs[task.rawValue].flatMap(configuration(forModelID:))
    }

    func setAuxiliaryModel(_ id: UUID?, for task: DesktopAuxiliaryModelTask) {
        guard id == nil || id.flatMap(configuration(forModelID:)) != nil else { return }
        auxiliaryModelIDs[task.rawValue] = id
        persist()
    }

    func apiKey(for id: UUID) throws -> String { try credentials.load(id: id) }

    func saveProvider(_ config: DesktopProviderConfiguration, apiKey: String) throws {
        let value = try validatedProvider(config)
        let otherIDs = providers.filter { $0.id != value.id }.flatMap { $0.models.map(\.id) }
        guard Set(otherIDs).isDisjoint(with: value.models.map(\.id)) else {
            throw DesktopRuntimeError.message("模型标识重复，请重新添加该模型。")
        }
        try credentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), id: value.id)
        if let index = providers.firstIndex(where: { $0.id == value.id }) { providers[index] = value }
        else { providers.append(value) }
        repairSelection()
        removeUnavailableAuxiliaryModels()
        persist()
    }

    // Imported settings never overwrite an existing provider or touch Keychain.
    @discardableResult func importProviderCopies(_ configs: [DesktopProviderConfiguration]) throws -> [UUID] {
        let copies = try configs.map { config in
            let source = try validatedProvider(config)
            var copy = source
            copy.id = UUID()
            var modelIDs: [UUID: UUID] = [:]
            copy.models = source.models.map { model in
                var value = model
                value.id = UUID(); modelIDs[model.id] = value.id
                return value
            }
            copy.selectedModelID = source.selectedModelID.flatMap { modelIDs[$0] }
            return try validatedProvider(copy)
        }
        guard !copies.isEmpty else { return [] }
        providers += copies
        repairSelection()
        persist()
        return copies.map(\.id)
    }

    func removeImportedProviders(_ ids: [UUID]) {
        let removed = Set(ids)
        guard providers.contains(where: { removed.contains($0.id) }) else { return }
        providers.removeAll { removed.contains($0.id) }
        repairSelection()
        removeUnavailableAuxiliaryModels()
        persist()
    }

    private func validatedProvider(_ config: DesktopProviderConfiguration) throws -> DesktopProviderConfiguration {
        var value = config
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.baseURL.hasSuffix("/") { value.baseURL.removeLast() }
        guard !value.name.isEmpty else { throw DesktopRuntimeError.message("请填写服务商名称。") }
        guard !value.models.isEmpty || !(value.authMode == .apiKey || value.authMode.isPlan) else { throw DesktopRuntimeError.message("请至少添加一个模型。") }
        value.models = try value.models.map { try $0.validated(for: value.kind) }
        guard Set(value.models.map(\.id)).count == value.models.count else {
            throw DesktopRuntimeError.message("模型标识重复，请重新添加该模型。")
        }
        if value.authMode == .codexOAuth, value.kind != .responses {
            throw DesktopRuntimeError.message("Codex 登录须使用 Responses 协议。")
        }
        if value.authMode == .grokOAuth, value.kind != .openAI {
            throw DesktopRuntimeError.message("Grok 登录须使用 OpenAI 兼容协议。")
        }
        if value.authMode.isPlan {
            guard value.kind == .openAI else { throw DesktopRuntimeError.message("编程套餐须使用 OpenAI 兼容协议。") }
            if let base = value.authMode.planBaseURL { value.baseURL = base }
        }
        if value.authMode == .antigravityOAuth, value.kind != .gemini {
            throw DesktopRuntimeError.message("Antigravity 登录须使用 Gemini 协议。")
        }
        try Self.validateEndpoint(value.baseURL)
        return value
    }

    func deleteProvider(_ id: UUID) throws {
        try credentials.delete(id: id)
        providers.removeAll { $0.id == id }
        if selectedProviderID == id { selectedProviderID = providers.first?.id }
        repairSelection()
        removeUnavailableAuxiliaryModels()
        persist()
    }

    static func validateEndpoint(_ value: String) throws {
        guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && isLoopback(host)) else {
            throw DesktopRuntimeError.message("请使用 HTTPS API 地址；本机模型可使用 http://localhost 或回环 IP。地址中不能包含密钥、查询参数或片段。")
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    private func persist() {
        let record = Record(providers: providers, selectedProviderID: selectedProviderID,
            systemPrompt: systemPrompt, appearance: appearance, auxiliaryModelIDs: auxiliaryModelIDs,
            messageFontFamily: messageFontFamily, messageFontSize: messageFontSize,
            assistantName: assistantName, userNickname: userNickname,
            reasoningExpandedByDefault: reasoningExpandedByDefault, autoExpandThinking: autoExpandThinking,
            automaticallyFollowGeneration: automaticallyFollowGeneration, hidesToolCalls: hidesToolCalls, sendShortcut: sendShortcut, notificationsEnabled: notificationsEnabled,
            speechVoiceIdentifier: speechVoiceIdentifier, speechRate: speechRate,
            agentToolRoundLimit: agentToolRoundLimit, agentRunMinutes: agentRunMinutes)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.persistedSettingsKey)
            settingsRecoveryMessage = nil
        }
    }

    private func repairSelection() {
        for index in providers.indices { providers[index].selectedModelID = providers[index].selectedModel?.id }
        let configured = providers.filter { provider in
            provider.selectedModel.map { !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
        if !configured.contains(where: { $0.id == selectedProviderID }), let first = configured.first {
            selectedProviderID = first.id
            return
        }
        if !providers.contains(where: { $0.id == selectedProviderID && $0.selectedModel != nil }) {
            selectedProviderID = providers.first(where: { $0.selectedModel != nil })?.id
        }
    }

    private func removeUnavailableAuxiliaryModels() {
        let available = Set(modelSelections.map(\.id))
        auxiliaryModelIDs = auxiliaryModelIDs.filter { available.contains($0.value) }
    }
}
