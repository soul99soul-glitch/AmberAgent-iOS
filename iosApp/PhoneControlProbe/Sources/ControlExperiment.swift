import Foundation
import UIKit
import Security
import AmberPhoneControl
import AmberIPhoneControl

@MainActor @Observable
final class ControlExperiment {
    private(set) var lines: [String] = []
    private(set) var isRunning = false
    private let session = PhoneControlSession()
    private let log = ProbeExperimentLog()
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    func preparePairing() {
        guard !isRunning else { return }
        isRunning = true
        task = Task {
            defer { isRunning = false; task = nil }
            do {
                await log.reset()
                if try await Task.detached(operation: { try ProbePairingStore.containsRecord() }).value {
                    await record("已有本机配对记录，可直接启动读树验证；未创建新的系统配对")
                    return
                }
                await record("发起系统 RemotePairing 初始化；系统如需同意，将显示设备提示")
                let ownHost = ProcessInfo.processInfo.arguments.contains("--pairing-over-wifi")
                    ? ProbeModel.wifiAddress() : nil
                let endpoint = "\(ownHost ?? "127.0.0.1"):49152"
                await record("本次显式配对入口：\(endpoint)")
                let preparation = Task.detached { [self] in
                    try await Self.prepareOnDevice(endpoint: endpoint) { [self] message in await record(message) }
                }
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                try await Task.detached { try ProbePairingStore.save(prepared) }.value
                await record("本机配对已完成，材料已保存到本机 Keychain")
            } catch { await record("配对未完成：\(error.localizedDescription)") }
        }
    }

    nonisolated private static func prepareOnDevice(endpoint: String, progress: @Sendable (String) async -> Void) async throws -> Data {
        // This is a diagnostic worker, never the UI actor. The native API copies input.
        guard let handle = amber_iphone_control_pairing_start(endpoint) else {
            throw PhoneControlSessionError.launch("无法创建配对任务")
        }
        defer { amber_iphone_control_free(handle) }
        var previousPhase = ""
        while true {
            try Task.checkCancellation()
            guard let raw = amber_iphone_control_status_json(handle) else {
                throw PhoneControlSessionError.launch("配对状态不可读")
            }
            let data = Data(String(cString: raw).utf8)
            amber_iphone_control_string_free(raw)
            let status = try JSONDecoder().decode(PhoneControlLaunchStatus.self, from: data)
            if previousPhase != status.phase {
                previousPhase = status.phase
                await progress("配对阶段：\(status.phase) · \(status.message)")
            }
            if status.phase == "paired", let raw = amber_iphone_control_pairing_copy_plist(handle) {
                defer { amber_iphone_control_string_free(raw) }
                return Data(String(cString: raw).utf8)
            }
            if status.phase == "failed" || status.phase == "stopped" {
                let code = status.native_error_code.map { " (code \($0))" } ?? ""
                throw PhoneControlSessionError.launch(status.message + code)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func start() {
        guard !isRunning else { return }
        let id = UUID()
        runID = id
        isRunning = true
        lines = []
        // P1 only: a finite UIKit grace period. This does not claim continued-task adoption.
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Amber self-control primitive") { [weak self] in
            self?.stop(reason: "UIKit 后台短窗到期")
        }
        task = Task { await perform(runID: id) }
    }

    func stop(reason: String = "用户停止") {
        task?.cancel()
        guard let id = runID else { return }
        Task {
            await record(reason)
            await session.stop(runID: id)
        }
    }

    private func perform(runID id: UUID) async {
        let monitor = Task {
            var previous = ""
            while !Task.isCancelled {
                if let status = try? await session.launchStatus() {
                    let text = "启动阶段：\(status.phase) · \(status.message)"
                    if text != previous { previous = text; await record(text) }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        do {
            await log.reset()
            await record("手机新建测试会话；仅允许 app.amber.selfcontrol.target")
            let pairing = try await Task.detached { try ProbePairingStore.loadOrImport() }.value
            let configuration = PhoneControlLaunchConfiguration(
                pairing: pairing, allowedBundleIDs: ["app.amber.selfcontrol.target"])
            let ready = try await session.start(runID: id, configuration: configuration)
            await record("签名 HTTP 已就绪：\(ready.ready)")
            let (_, unsignedResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8100/status")!)
            guard (unsignedResponse as? HTTPURLResponse)?.statusCode == 401 else {
                throw PhoneControlSessionError.launch("未签名请求没有被 401 拒绝，停止验证")
            }
            await record("未签名 status 请求已被拒绝")
            let client = try await session.runner(runID: id)
            try await requireCompleted(client.act(.launch(bundleID: "app.amber.selfcontrol.target")))
            let first = try await client.observe()
            await record("已读取当前 App 的树：\(first.bundleID)，\(first.nodes.count) 个节点")
            guard let beforeCount = first.nodes.first(where: { $0.identifier == "probe.count" })?.label,
                  let expectedCount = Int(beforeCount.replacingOccurrences(of: "当前计数：", with: "")) else {
                throw PhoneControlSessionError.launch("树中未找到可解析的靶场计数")
            }
            guard let node = first.nodes.first(where: { $0.identifier == "probe.increment" }), let ref = node.ref else {
                throw PhoneControlSessionError.launch("树中未找到靶场计数按钮")
            }
            try await requireCompleted(client.act(.tap(ref: ref)))
            let after = try await client.observe()
            let counter = after.nodes.first(where: { $0.identifier == "probe.count" })
            await record("点击后的新树：\(counter?.label ?? "未找到计数文本")")
            guard counter?.label == "当前计数：\(expectedCount + 1)" else {
                throw PhoneControlSessionError.launch("协议动作已返回，但新树未证明计数增加一次")
            }
            await record("P1 原语闭环完成；尚不代表 3 分钟后台或模型循环通过")
        } catch {
            await record("实验结束：\(error.localizedDescription)")
        }
        monitor.cancel()
        await session.stop(runID: id)
        await record("本轮测试连接已释放")
        guard runID == id else { return }
        runID = nil
        task = nil
        isRunning = false
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
    }

    private func requireCompleted(_ result: PhoneActionResult) async throws {
        switch result {
        case .completed: await record("动作协议已返回完成；继续读取业务后验")
        case .unsent(let problem): throw PhoneControlSessionError.launch("动作未派发：\(problem.localizedDescription)")
        case .unknown(let problem): throw PhoneControlSessionError.launch("动作结果未知，不重试：\(problem.localizedDescription)")
        }
    }

    private func record(_ message: String) async {
        lines.append(message)
        print("AMBER_SELF_CONTROL \(message)")
        await log.append(message)
    }
}

private actor ProbeExperimentLog {
    private var lines: [String] = []
    func reset() { lines = [] }
    func append(_ text: String) {
        lines.append("\(Date().ISO8601Format()) \(text)")
        do {
            try lines.joined(separator: "\n").write(to: URL.documentsDirectory.appending(path: "control-experiment.txt"),
                                                   atomically: true, encoding: .utf8)
        } catch { print("AMBER_SELF_CONTROL diagnostic write failed") }
    }
}

private enum ProbePairingStore {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.amber.selfcontrol.probe.pairing",
        kSecAttrAccount as String: "local-device",
    ] }

    static func containsRecord() throws -> Bool {
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw PhoneControlSessionError.launch("Keychain 不可读 (\(status))")
    }

    static func save(_ data: Data) throws {
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw PhoneControlSessionError.launch("配对信息保存失败 (\(saved))") }
    }

    static func loadOrImport() throws -> Data {
        var read = query
        read[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }
        guard status == errSecItemNotFound else { throw PhoneControlSessionError.launch("Keychain 不可读 (\(status))") }
        let path = URL.documentsDirectory.appending(path: "amber-pairing.plist")
        let data = try Data(contentsOf: path)
        try save(data)
        // This is only the task-owned one-time transfer file, after a successful Keychain write.
        try FileManager.default.removeItem(at: path)
        return data
    }
}
