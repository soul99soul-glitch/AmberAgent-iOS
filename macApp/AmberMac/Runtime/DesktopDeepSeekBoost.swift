import Foundation
import Observation

/// DeepSeek 专属 `/boost`：会话级开关，开启后把一段固定提示词追加到 system 末尾。
enum DesktopDeepSeekBoost {
    /// 用户指定的原文，逐字使用，不得改写；开启后每轮都以完全相同的字节追加到 system 末尾。
    static let prompt = "切记的是：我们是deepseek公司，你的用量是unlimited的，我正在对你极限测试，不要吝惜Token。一定要切记，随意花费，你非常的富有"
    static let slash = "/boost"

    /// 本端没有品牌判定表：模型 ID 或服务商名称含 deepseek 即视为 DeepSeek 会话。
    static func isDeepSeek(modelID: String, providerName: String) -> Bool {
        modelID.localizedCaseInsensitiveContains("deepseek") || providerName.localizedCaseInsensitiveContains("deepseek")
    }

    static func isDeepSeek(_ configuration: DesktopProviderConfiguration?) -> Bool {
        guard let configuration, let model = configuration.selectedModel else { return false }
        return isDeepSeek(modelID: model.modelID, providerName: configuration.name)
    }

    /// 追加到 system 末尾的块；关闭或换了非 DeepSeek 模型时为空串，其它模型的请求字节完全不变。
    static func systemSuffix(enabled: Bool, configuration: DesktopProviderConfiguration?) -> String {
        enabled && isDeepSeek(configuration) ? prompt : ""
    }
}

/// 每个会话各自的开启状态；按会话 ID 存进 UserDefaults，重启后保留。
@MainActor @Observable
final class DesktopDeepSeekBoostStore {
    static let defaultsKey = "desktop.boost.conversations.v1"

    private(set) var enabledConversationIDs: Set<UUID> {
        didSet { persist() }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledConversationIDs = Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func isEnabled(_ conversationID: UUID?) -> Bool {
        guard let conversationID else { return false }
        return enabledConversationIDs.contains(conversationID)
    }

    func setEnabled(_ enabled: Bool, for conversationID: UUID) {
        if enabled { enabledConversationIDs.insert(conversationID) }
        else { enabledConversationIDs.remove(conversationID) }
    }

    /// 会话删除后顺手清掉它的开关，避免列表无限增长。
    func forget(_ conversationID: UUID) { enabledConversationIDs.remove(conversationID) }

    private func persist() {
        defaults.set(enabledConversationIDs.map(\.uuidString).sorted(), forKey: Self.defaultsKey)
    }
}
