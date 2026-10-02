import Foundation

enum IOSExecutionPreferenceKeys {
    static let liveActivity = "app.amber.ios.execution.liveActivity"
    /// 历史音频保活偏好 key。稳定版不声明 audio background mode，因此始终关闭；
    /// 仅保留给明确声明该模式的内部构建读取。
    static let audioKeepAlive = "app.amber.ios.execution.audioKeepAlive"
    /// G7: 前台单轮工具循环上限（默认 24，clamp 24-384）。与
    /// ExecutionSettingsView 的 @AppStorage / SettingsStore 共用同一 key。
    static let chatMaxToolResumeCount = "app.amber.ios.execution.chatMaxToolResumeCount"
    /// Experimental-only optional location background activity. Stable builds
    /// do not declare the location background mode, so the runtime guard keeps
    /// this preference inert there.
    static let backgroundLocationKeepAlive = "app.amber.ios.execution.backgroundLocationKeepAlive"
    /// P3-a: exec 纯求值工具总开关（默认关）。与 ExecutionSettingsView 的
    /// @AppStorage / SettingsStore 共用同一 key。
    static let execJavaScriptEnabled = "app.amber.ios.execution.execJavaScriptEnabled"
}
