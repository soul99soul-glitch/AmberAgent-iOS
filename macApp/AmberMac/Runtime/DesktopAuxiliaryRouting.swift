import Foundation

@MainActor enum DesktopAuxiliaryRouting {
    static func chatConfiguration(settings: DesktopSettings, hasImages: Bool) throws -> DesktopProviderConfiguration? {
        guard let selected = settings.selectedProvider else { return nil }
        guard hasImages else { return selected }
        if selected.selectedModel?.supportsVision == true { return selected }
        if let fallback = settings.configuredAuxiliaryModel(for: .vision) {
            guard fallback.selectedModel?.supportsVision != false else {
                throw DesktopRuntimeError.message("视觉辅助模型被设为仅文本，请在模型设置中修改能力或选择支持图片的模型。")
            }
            return fallback
        }
        guard selected.selectedModel?.supportsVision != false else {
            throw DesktopRuntimeError.message("当前模型仅支持文本，请选择支持图片的模型，或在辅助任务中指定视觉模型。")
        }
        return selected
    }
}
