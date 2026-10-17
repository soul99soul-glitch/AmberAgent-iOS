import SwiftUI

@main
struct AmberAgentApp: App {
    @UIApplicationDelegateAdaptor(AmberAppDelegate.self) private var appDelegate
    @State private var settingsStore = SettingsStore()

    init() {
        IOSAppLanguagePreference.normalize()
        // Explicit device acceptance uses the normal new-conversation/model/tool path.
        if ProcessInfo.processInfo.arguments.contains("-amber-phone-popup-close-inspection-once") {
            Task { @MainActor in
                guard IOSPhoneControlController.shared.enabled,
                      !IOSPhoneControlController.shared.isOccupied,
                      let destination = IOSDeepLinkInbox.shared.preparePromptHandoff(
                        "验证手机控制修复：打开美团外卖 com.meituan.itakeaway，仅关闭当前营销弹窗。先读取新截图；若关闭按钮没有独立 ref，使用最新截图的 observation_id 和归一化坐标调用 phone_act tap_point。只点关闭 X，不买券、不下单、不付款、不发消息，不进入其它页面。动作后重新截图确认弹窗消失，完成即停止；如果没有该弹窗，只报告，不寻找或制造弹窗。"
                      ), let url = IOSAppDeepLink.url(for: destination) else { return }
                IOSDeepLinkInbox.shared.submit(url)
            }
        }
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        let restoreClashSelection = ProcessInfo.processInfo.arguments.contains("-amber-phone-clashmi-restore-inspection-once")
        if restoreClashSelection || ProcessInfo.processInfo.arguments.contains("-amber-phone-clashmi-setup-inspection-once") {
            Task { @MainActor in
                guard IOSPhoneControlController.shared.enabled,
                      !IOSPhoneControlController.shared.isOccupied,
                      let destination = IOSDeepLinkInbox.shared.preparePromptHandoff(
                        restoreClashSelection
                        ? "恢复本轮兼容测试的临时选择。只操作 Clash Mi（com.nebula.clashmi）：打开后若出现 LibclashStart failed、dns.nameserver-policy 的错误提示，只点确定关闭提示；进入核心设置的覆写页面。仅当当前选择为 Amber 本机回环时，将选择恢复为内置-覆写，重新观察确认保存，然后 phone_stop。若已为内置-覆写，直接报告并 phone_stop；若为其他选择，不修改并 phone_stop。保留 Amber 本机回环条目以供后续诊断，不删除、不编辑任何覆写，不查看或输出订阅链接、密钥，不改 DNS、订阅、节点或分流规则，不连接或断开 VPN。只恢复选择，遇到失败或未知结果立即停止，不重复动作。"
                        :
                        "本轮是用户已批准的手机控制兼容验证。只操作 Clash Mi（com.nebula.clashmi）：先用 phone_apps 查找，必要时 phone_add_app 加入范围，再打开它。只点导航类控件进入自定义覆写页面，报告当前选择名称。若顶部系统进度卡展开挡住导航，基于最新截图用 swipe_point 从卡片中央文字区向上滑到接近屏幕顶部，避开 App 图标和取消键；本轮最多一次，之后必须重新截图确认卡片收起且仍在 Clash Mi。未收起、切到 Amber 或任务中断即停止，不继续点被挡的控件。卡片收起后，用新截图定位添加按钮，只点一次并重新观察；仍未打开添加界面就停止，报告该次点击前卡片是否已收起。如果当前是自定义覆写或内置-不覆写，保持原样并 phone_stop，不覆盖原内容。只有当前为内置-覆写时，才新增名为 Amber 本机回环的自定义覆写，从此固定地址导入：https://raw.githubusercontent.com/tom-snow/Sidestore-ClashMi/02b5542ccbbb4453c5958c765f061d4d56c48eab/profile_overwrite_min.yaml 。它仅包含 tun 下的 loopback-address 列表 10.7.0.1。新覆写的追加覆写必须设为内置-覆写，以保留 App 原有设置的叠加方式，然后将当前选择切换到新覆写；除此之外不修改其他配置。若已有同名覆写，停止报告，不重复创建。保存后重新观察确认当前选择及追加覆写，报告修改前后的名称，然后 phone_stop。不要连接、断开或切换 VPN，不修改订阅、节点、分流模式，不查看或输出订阅链接和密钥，不发消息、不购买。如果观察到 Clash Mi 连接状态变化，立即 phone_stop 并报告，不自行再切换。遇到界面不支持、下载失败或动作结果未知立即停止并报告，不换路径反复尝试。"
                      ), let url = IOSAppDeepLink.url(for: destination) else { return }
                IOSDeepLinkInbox.shared.submit(url)
            }
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlDirectConnectionInspection.Mode.remotePairingIPv6.launchArgument) {
            Task { @MainActor in await IOSPhoneControlDirectConnectionInspection.runOnce(mode: .remotePairingIPv6) }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlDirectConnectionInspection.Mode.lockdownIPv4.launchArgument) {
            Task { @MainActor in await IOSPhoneControlDirectConnectionInspection.runOnce(mode: .lockdownIPv4) }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlEmbeddedTunnelInspection.diagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlEmbeddedTunnelInspection.runOnce() }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlHandshakeInspection.routedDiagnosticLaunchArgument) {
            Task { @MainActor in
                await IOSPhoneControlHandshakeInspection.runOnce(source: "routed_diagnostic", inspectCurrentRoute: true)
            }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlHandshakeInspection.diagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlHandshakeInspection.runOnce() }
        }
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlReadinessInspection.existingVPNDiagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlReadinessInspection.runExistingVPNOnce() }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlReadinessInspection.applicationsDiagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlReadinessInspection.runApplicationsOnce() }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlReadinessInspection.inputDiagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlReadinessInspection.runOnce(inspectInput: true) }
        } else if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlReadinessInspection.diagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlReadinessInspection.runOnce() }
        }
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlSelfDiscovery.diagnosticLaunchArgument) {
            Task { @MainActor in await IOSPhoneControlSelfDiscovery.shared.start() }
        }
        if ProcessInfo.processInfo.arguments.contains(IOSPhoneControlServiceInspection.diagnosticLaunchArgument) {
            Task { @MainActor in
                await IOSPhoneControlServiceInspection().inspectAndRecord(source: "launch")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if CHAT_PERF_REPLAY
                ChatPerfReplayView()
#elseif DEBUG && INTELLIGENT_UI_COMPONENT_ACCEPTANCE
                if let kind = IOSIntelligentUIAcceptanceFixtureView.Kind.requested {
                    IOSIntelligentUIAcceptanceFixtureView(kind: kind)
                } else {
                    AppShell(settingsStore: settingsStore)
                }
#else
                AppShell(settingsStore: settingsStore)
#endif
            }
        }
    }
}
