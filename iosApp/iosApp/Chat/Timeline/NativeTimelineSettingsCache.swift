import Foundation
import Shared

/// KMP settings are immutable data classes. Keep the source references as well
/// as their hashes so a replacement setting invalidates without per-row bridging.
@MainActor
final class NativeTimelineSettingsCache {
    private var displaySource: DisplaySetting?
    private var generativeSource: GenerativeUiSetting?
    private var displayHash = 0
    private var generativeHash = 0

    func display(_ value: DisplaySetting, fontScale: Double, chatFont: String, agentName: Bool) -> Int {
        if displaySource !== value {
            displaySource = value
            displayHash = String(describing: value).hashValue
        }
        var signature = Hasher()
        signature.combine(displayHash)
        signature.combine(IOSChatFont.clampedScale(fontScale))
        signature.combine(chatFont)
        signature.combine(agentName)
        return signature.finalize()
    }

    func generative(_ value: GenerativeUiSetting) -> Int {
        if generativeSource !== value {
            generativeSource = value
            generativeHash = String(describing: value).hashValue
        }
        return generativeHash
    }
}
