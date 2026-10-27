import AppKit
import Foundation
import Observation
import ServiceManagement

/// 「关闭窗口后继续在菜单栏运行」and「登录时启动」.
@MainActor @Observable final class DesktopBackgroundMode {
    /// nil = follow the default: on while any scheduled task is enabled.
    private(set) var keepRunningPreference: Bool?
    private(set) var launchAtLogin = false
    private(set) var loginItemMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hasScheduledWork: @MainActor () -> Bool

    private static let keepRunningKey = "desktop.keep-running-in-menu-bar"

    init(defaults: UserDefaults = .standard, hasScheduledWork: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.hasScheduledWork = hasScheduledWork
        keepRunningPreference = defaults.object(forKey: Self.keepRunningKey) as? Bool
        refreshLoginItem()
    }

    /// The main window was closed and the app went to the menu bar. Stays set until a window is shown again, so the
    /// app never quits on its own just because the last task finished or switched itself off.
    private(set) var isMenuBarOnly = false

    /// Default (no explicit choice): on while a task is enabled or running, or once already in the menu bar.
    var keepsRunning: Bool { keepRunningPreference ?? (isMenuBarOnly || hasScheduledWork()) }

    func setKeepsRunning(_ value: Bool) {
        keepRunningPreference = value
        defaults.set(value, forKey: Self.keepRunningKey)
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginItemMessage = status == .requiresApproval ? "需要在「系统设置 › 通用 › 登录项」中允许 Amber。" : nil
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemMessage = (value ? "无法设为登录时启动：" : "无法取消登录时启动：") + error.localizedDescription
        }
    }

    /// No visible regular window left: drop the Dock icon but keep the menu bar item.
    func enterMenuBarOnly() {
        isMenuBarOnly = true
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    func showDockIcon() {
        isMenuBarOnly = false
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }
}
