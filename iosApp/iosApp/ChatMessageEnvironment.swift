import SwiftUI

private struct ChatMessageEditingAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var chatMessageEditingAllowed: Bool {
        get { self[ChatMessageEditingAllowedKey.self] }
        set { self[ChatMessageEditingAllowedKey.self] = newValue }
    }
}
