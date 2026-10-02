import Foundation

/// How the host app names the model that "follow global" novel roles use.
/// Amber falls back to its global chat model; the standalone Novel app sets its
/// own default-model wording once at launch, before any view reads it.
/// The values are localization keys.
struct NovelGlobalModelWording: Sendable {
    var followTitle = "跟随当前聊天模型"
    var followValueFormat = "跟随聊天 · %@"
    var missingModelMessage = "还没有可用的全局聊天模型，请先在设置里配好服务商和默认模型。"

    nonisolated(unsafe) static var current = NovelGlobalModelWording()
}
