import Foundation
import Observation
import UIKit

/// Owns the Mac Gateway pairing: persistence, APNs token upload and the status shown in Settings.
@MainActor
@Observable
final class MacGatewayStore {
    static let shared = MacGatewayStore()

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private static let connectionKey = "macGateway.connection.v1"
    private static let tokenKey = "macGateway.deviceToken"

    /// Debug builds are signed with `aps-environment = development` (project.yml), Release with production.
    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private(set) var connection: MacGatewayConnection? { didSet { publishBoard() } }
    private(set) var status: MacGatewayStatus? { didSet { publishBoard() } }
    /// nil until the first refresh after launch or pairing.
    private(set) var isReachable: Bool? { didSet { publishBoard() } }
    private(set) var isBusy = false
    private(set) var isSendingTestPush = false
    private(set) var pushError: String?
    /// Approvals being sent, by tool call id; their buttons show progress.
    private(set) var decidingCalls: Set<String> = []
    /// Amber scheduled tasks on the Mac; nil until fetched, or when Amber isn't running there.
    private(set) var schedules: [MacGatewaySchedule]?
    private(set) var schedulesError: String?
    private(set) var busySchedules: Set<String> = []
    /// The Mac's task board; nil until fetched, or when Amber isn't running there (see `boardItems`).
    private(set) var board: [MacGatewayBoardItem]? { didSet { publishBoard() } }
    /// The board as shown: the Mac's, or without Amber a read-only one built from the gateway's sessions.
    /// Stored, and written only on change, so views don't re-render on every poll.
    private(set) var boardItems: [MacGatewayBoardItem] = []
    /// Cards waiting on the user; empty while unpaired or unreachable, so a stale count never shows on Home.
    private(set) var needsYouItems: [MacGatewayBoardItem] = []
    /// Why the board came from the gateway alone (Amber not running, or an older gateway).
    private(set) var boardError: String?
    var pendingPairing: MacGatewayPairingPayload?
    var notice: Notice?

    @ObservationIgnored private var client: MacGatewayClient?
    @ObservationIgnored private var apnsToken: String?
    /// Bumped per request so a slower, older response never overwrites a newer one (polls, pull to refresh and
    /// the refresh after a decision overlap).
    @ObservationIgnored private var requestGeneration = (status: 0, schedules: 0, board: 0)
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(MacGatewayConnection.self, from: data),
           let token = IOSCredentialSideTable.load(key: Self.tokenKey) {
            connection = saved
            client = MacGatewayClient(addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: token)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AMBER_MAC_BOARD_FIXTURE"] == "1" { loadBoardFixture() }
        #endif
    }

    #if DEBUG
    /// Simulator screenshots of every board group without a Mac: no client, so nothing is sent anywhere.
    private func loadBoardFixture() {
        let now = Date()
        connection = MacGatewayConnection(gatewayId: "fixture", name: "Studio Mac", addrs: [], port: 1, fingerprint: "", deviceId: "d")
        client = nil
        isReachable = true
        func item(_ id: String, _ kind: MacGatewayBoardItem.Kind, _ column: MacGatewayBoardItem.Column, _ title: String,
                  _ detail: String, ago: TimeInterval = 0, schedule: String? = nil, next: Date? = nil, reply: Bool = false,
                  failed: Bool = false, approval: MacGatewayBoardItem.Approval? = nil) -> MacGatewayBoardItem {
            MacGatewayBoardItem(id: id, kind: kind, column: column, title: title, detail: detail, updatedAt: now - ago,
                                scheduleId: schedule, nextRunAt: next, waitingForReply: reply, failed: failed, approval: approval)
        }
        board = [
            item("run:A", .run, .needsYou, "每日新闻汇总", "等你确认 · workspace_file_write", ago: 120, schedule: "A",
                 approval: .init(sessionKey: "amber:r1", toolCallId: "c1", tool: "workspace_file_write",
                                 detail: "path: notes/2026-10-27.md", highRisk: false)),
            item("run:B", .run, .needsYou, "清理下载文件夹", "等你确认 · shell_run", ago: 300, schedule: "B",
                 approval: .init(sessionKey: "amber:r2", toolCallId: "c2", tool: "shell_run",
                                 detail: "rm -rf ~/Downloads/tmp", highRisk: true)),
            item("session:claude:s1", .agentSession, .needsYou, "实现 iOS 任务看板", "Claude Code · Synara · 等你回复", ago: 60, reply: true),
            item("session:codex:s2", .agentSession, .running, "修复网关推送", "Codex · 运行中", ago: 30),
            item("schedule:C", .schedule, .scheduled, "周报", "每周五 17:30", schedule: "C", next: now + 3 * 3600),
            item("done:R1", .run, .done, "每日新闻汇总", "整理了 12 条新闻，没有需要你关注的", ago: 86_400, schedule: "A"),
            item("done:R2", .run, .done, "清理下载文件夹", "磁盘空间不足", ago: 2 * 86_400, schedule: "B", failed: true),
        ]
        schedules = [
            MacGatewaySchedule(id: "C", name: "周报", rule: "每周五 17:30", enabled: true, running: false, nextRunAt: now + 3 * 3600,
                               autoApprovesHighRisk: false),
            MacGatewaySchedule(id: "D", name: "备份照片", rule: "每天 03:00", enabled: false, running: false, autoApprovesHighRisk: false),
        ]
    }
    #endif

    // MARK: - App lifecycle

    /// Apple recommends re-registering on every launch; the token can change after restores and updates.
    func applicationDidFinishLaunching() {
        guard connection != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = hex
        guard connection != nil else { return }
        Task { await uploadPushToken(hex) }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        guard connection != nil else { return }
        pushError = error.localizedDescription
    }

    // MARK: - Pairing

    /// Deep link entry (system camera scan or AirDrop). Pairing still needs an explicit confirmation.
    func receivePairingLink(_ link: String) {
        guard let payload = MacGatewayPairingPayload.parse(link) else {
            notice = Notice(text: localized("配对链接无效，请在 Mac 上重新运行 amber-gateway pair"), isError: true)
            return
        }
        pendingPairing = payload
        notice = nil
    }

    func pasteLinkFromClipboard() {
        receivePairingLink(UIPasteboard.general.string ?? "")
    }

    func confirmPairing() async {
        guard let payload = pendingPairing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let pairingClient = MacGatewayClient(addrs: payload.addrs, port: payload.port, fingerprint: payload.fp, token: nil)
        do {
            let response = try await pairingClient.pair(secret: payload.s, deviceName: UIDevice.current.name)
            guard IOSCredentialSideTable.store(key: Self.tokenKey, value: response.token) else {
                notice = Notice(text: localized("无法把配对凭据写入钥匙串"), isError: true)
                return
            }
            let saved = MacGatewayConnection(gatewayId: response.gatewayId, name: response.gatewayName, addrs: payload.addrs,
                                             port: payload.port, fingerprint: payload.fp, deviceId: response.deviceId)
            defaults.set(try? JSONEncoder().encode(saved), forKey: Self.connectionKey)
            connection = saved
            client = MacGatewayClient(addrs: saved.addrs, port: saved.port, fingerprint: saved.fingerprint, token: response.token)
            pendingPairing = nil
            notice = nil
            await enablePush()
            await refresh()
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    func unpair() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Best effort: if the Mac is unreachable the device stays listed there until `devices revoke`.
        // 401 means the Mac already dropped this device, which is the outcome we wanted.
        var reachedMac = true
        do {
            try await client?.unpair()
        } catch MacGatewayError.unauthorized {
        } catch {
            reachedMac = false
        }
        forget()
        notice = reachedMac ? nil : Notice(text: localized("已在本机取消配对。Mac 当前不可达，可在 Mac 上运行 amber-gateway devices revoke 移除此设备"), isError: false)
    }

    // MARK: - Status & control

    func refresh() async {
        guard let client else { return }
        requestGeneration.status += 1
        let generation = requestGeneration.status
        do {
            let latest = try await client.status()
            guard self.client === client, generation == requestGeneration.status else { return }
            status = latest
            isReachable = true
            await refreshSchedules()
            await refreshBoard()
            if latest.device.pushRegistered {
                pushError = nil
            } else if let apnsToken {
                // The Mac lost the token (or an earlier upload failed while it was offline): report it again.
                await uploadPushToken(apnsToken)
            }
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.status else { return }
            if !forgetIfRevoked(error) { isReachable = false }
        }
    }

    func setMonitored(_ session: MacGatewayStatus.Session, _ monitored: Bool) async {
        guard let client, let index = status?.sessions.firstIndex(where: { $0.key == session.key }) else { return }
        status?.sessions[index].monitored = monitored
        do {
            try await client.setMonitored(taskKey: session.key, monitored: monitored)
        } catch {
            if let i = status?.sessions.firstIndex(where: { $0.key == session.key }) { status?.sessions[i].monitored = !monitored }
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
    }

    func sendTestPush() async {
        guard let client, !isSendingTestPush else { return }
        isSendingTestPush = true
        defer { isSendingTestPush = false }
        do {
            try await client.testPush()
            notice = Notice(text: localized("测试推送已发出，锁屏后留意通知"), isError: false)
        } catch {
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
    }

    /// Phone-side answer to an Amber scheduled run's tool call. The Mac re-checks the call and the risk class.
    @discardableResult
    func decide(sessionKey: String, toolCallId: String, allow: Bool) async -> Bool {
        guard let client else {
            notice = Notice(text: localized("未与 Mac 配对"), isError: true)
            return false
        }
        guard decidingCalls.insert(toolCallId).inserted else { return false }
        defer { decidingCalls.remove(toolCallId) }
        do {
            try await client.decide(sessionKey: sessionKey, toolCallId: toolCallId, allow: allow)
            notice = Notice(text: localized(allow ? "已批准，Mac 上的任务继续运行" : "已拒绝这次调用"), isError: false)
            await refresh()
            return true
        } catch {
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
            await refresh()
            return false
        }
    }

    // MARK: - Task board

    var needsYouCount: Int { needsYouItems.count }

    private func publishBoard() {
        let items = board ?? Self.fallbackBoard(sessions: status?.sessions ?? [])
        if items != boardItems { boardItems = items }
        let needsYou = connection != nil && isReachable == true ? items.filter { $0.column == .needsYou } : []
        if needsYou != needsYouItems { needsYouItems = needsYou }
    }

    func refreshBoard() async {
        guard let client else { return }
        requestGeneration.board += 1
        let generation = requestGeneration.board
        do {
            let latest = try await client.board()
            guard self.client === client, generation == requestGeneration.board else { return }
            board = latest
            boardError = nil
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.board else { return }
            if forgetIfRevoked(error) { return }
            board = nil
            // Gateways older than the board answer 404 "not found".
            boardError = error as? MacGatewayError == .server("not found")
                ? localized("Mac 上的 amber-gateway 版本较旧，更新 Amber 后可查看定时任务和审批")
                : error.localizedDescription
        }
    }

    /// Claude Code / Codex sessions, plus Amber runs the gateway reports as waiting on a tool call (still answerable
    /// with `decide`). Schedules are unknown without Amber. Same grouping as the Mac's board.
    static func fallbackBoard(sessions: [MacGatewayStatus.Session]) -> [MacGatewayBoardItem] {
        let order = MacGatewayBoardItem.Column.allCases
        let approvals = sessions.compactMap { session -> MacGatewayBoardItem? in
            guard session.agent == "amber", let pending = session.pendingApproval else { return nil }
            return MacGatewayBoardItem(
                id: "run:\(session.key)", kind: .run, column: .needsYou, title: session.displayTitle,
                detail: IOSAppLocalization.string("等你确认", defaultValue: "等你确认") + " · " + pending.tool,
                updatedAt: session.updatedAt, scheduleId: nil, nextRunAt: nil, waitingForReply: false, failed: false,
                approval: .init(sessionKey: session.key, toolCallId: pending.toolCallId, tool: pending.tool,
                                detail: pending.detail, highRisk: pending.highRisk))
        }
        // Same rule as the Mac's board: sessions with no prompt have nothing to show but their directory name.
        let items = approvals + sessions.filter { $0.agent != "amber" && $0.agent != "run" }
            .filter { $0.summary != nil || $0.state == "waiting" }.map { session in
            let column: MacGatewayBoardItem.Column = switch session.state {
            case "waiting": .needsYou
            case "running", "stalled": .running
            default: .done
            }
            return MacGatewayBoardItem(
                id: "session:\(session.key)", kind: .agentSession, column: column, title: session.displayTitle,
                detail: fallbackDetail(session), updatedAt: session.updatedAt, scheduleId: nil, nextRunAt: nil,
                waitingForReply: session.state == "waiting" && session.waitReason != "permission",
                failed: session.abnormal, approval: nil)
        }
        return items.sorted { a, b in
            let (ai, bi) = (order.firstIndex(of: a.column) ?? 0, order.firstIndex(of: b.column) ?? 0)
            return ai != bi ? ai < bi : a.updatedAt > b.updatedAt
        }
    }

    private static func fallbackDetail(_ session: MacGatewayStatus.Session) -> String {
        let agent = switch session.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: IOSAppLocalization.string("任务", defaultValue: "任务")
        }
        let state = switch session.state {
        case "running": "运行中"
        case "waiting": session.waitReason == "permission" ? "等你确认" : "等你回复"
        case "stalled": "可能卡住了"
        case "completed": "已完成"
        default: session.abnormal ? "意外中断" : "已停止"
        }
        return [agent, session.host, IOSAppLocalization.string(state, defaultValue: state)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Amber scheduled tasks

    func refreshSchedules() async {
        guard let client else { return }
        requestGeneration.schedules += 1
        let generation = requestGeneration.schedules
        do {
            let latest = try await client.schedules()
            guard self.client === client, generation == requestGeneration.schedules else { return }
            schedules = latest
            schedulesError = nil
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.schedules else { return }
            if forgetIfRevoked(error) { return }
            schedules = nil
            schedulesError = error.localizedDescription
        }
    }

    func setScheduleEnabled(_ schedule: MacGatewaySchedule, _ enabled: Bool) async {
        // Show the new position at once; the refresh after the call corrects it if the Mac refused.
        if let i = schedules?.firstIndex(where: { $0.id == schedule.id }) { schedules?[i].enabled = enabled }
        await scheduleAction(schedule.id) { try await $0.setScheduleEnabled(id: schedule.id, enabled: enabled) }
    }

    func runSchedule(_ schedule: MacGatewaySchedule) async {
        await scheduleAction(schedule.id, success: localized("已在 Mac 上开始运行")) { try await $0.runSchedule(id: schedule.id) }
    }

    /// Returns whether the Mac accepted the task; the sheet stays open on failure so nothing typed is lost.
    func createSchedule(_ draft: MacGatewayScheduleDraft) async -> String? {
        guard let client else { return localized("未与 Mac 配对") }
        do {
            try await client.createSchedule(draft)
            notice = Notice(text: localized("已在 Mac 上创建定时任务"), isError: false)
            await refreshSchedules()
            await refreshBoard()
            return nil
        } catch {
            if forgetIfRevoked(error) { return MacGatewayError.unauthorized.localizedDescription }
            return error.localizedDescription
        }
    }

    private func scheduleAction(_ id: String, success: String? = nil, _ body: (MacGatewayClient) async throws -> Void) async {
        guard let client, busySchedules.insert(id).inserted else { return }
        defer { busySchedules.remove(id) }
        do {
            try await body(client)
            if let success { notice = Notice(text: success, isError: false) }
        } catch {
            if !forgetIfRevoked(error) { notice = Notice(text: error.localizedDescription, isError: true) }
        }
        await refreshSchedules()
        await refreshBoard()
    }

    func enablePush() async {
        guard await IOSLocalNotificationService.shared.requestAuthorization() else {
            pushError = localized("通知权限未开启，请到系统设置 > Amber > 通知中开启")
            return
        }
        pushError = nil
        UIApplication.shared.registerForRemoteNotifications()
        if let apnsToken { await uploadPushToken(apnsToken) }
    }

    // MARK: - Private

    private func uploadPushToken(_ hex: String) async {
        guard let client else { return }
        do {
            try await client.registerPushToken(hex, environment: Self.apnsEnvironment)
            pushError = nil
            if status?.device.pushRegistered == false { status?.device.pushRegistered = true }
        } catch is CancellationError {
        } catch {
            if !forgetIfRevoked(error) { pushError = error.localizedDescription }
        }
    }

    /// 401 means the Mac revoked this device: drop the pairing everywhere, with the same explanation.
    private func forgetIfRevoked(_ error: Error) -> Bool {
        guard case MacGatewayError.unauthorized = error else { return false }
        forget()
        notice = Notice(text: MacGatewayError.unauthorized.localizedDescription, isError: true)
        return true
    }

    private func forget() {
        IOSCredentialSideTable.delete(key: Self.tokenKey)
        defaults.removeObject(forKey: Self.connectionKey)
        connection = nil
        client = nil
        status = nil
        schedules = nil
        schedulesError = nil
        board = nil
        boardError = nil
        isReachable = nil
        pushError = nil
    }

    private func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }
}
