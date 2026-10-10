import SwiftUI
import Network
import Darwin

@main
struct PhoneControlProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

@MainActor @Observable
final class ProbeModel {
    var entries: [String] = []
    var running = false

    func checkRoutes() async {
        guard !running else { return }
        running = true
        defer { running = false }
        entries = ["开始检查本机开发入口"]
        var hosts = ["127.0.0.1", "10.7.0.1"]
        if let ownAddress = Self.wifiAddress(), !hosts.contains(ownAddress) { hosts.append(ownAddress) }
        for host in hosts {
            let result = await TCPProbe.connect(host: host, port: 49152)
            let line = "\(host):49152 — \(result)"
            entries.append(line)
            print("AMBER_SELF_CONTROL \(line)")
        }
        entries.append("TCP 可达仅证明网络入口，不等于配对或 XCTest 授权。")
        let output = entries.joined(separator: "\n")
        let folder = URL.documentsDirectory
        do { try output.write(to: folder.appending(path: "route-probe.txt"), atomically: true, encoding: .utf8) }
        catch { entries.append("诊断保存失败：\(error.localizedDescription)") }
    }

    nonisolated static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0",
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

private struct ProbeView: View {
    @State private var model = ProbeModel()
    @State private var experiment = ControlExperiment()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("检查本机开发入口，并在自动化靶场验证读树与可逆操作。")
                        .foregroundStyle(.secondary)
                    Button("检查本机通道") { Task { await model.checkRoutes() } }
                        .disabled(model.running)
                        .accessibilityIdentifier("probe.checkRoutes")
                }
                if model.running { ProgressView("检查中") }
                if !model.entries.isEmpty {
                    Section("诊断记录") {
                        ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                            Text(entry).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
                Section("本机测试会话") {
                    Text("先安装开发签名的 runner，再初始化本机配对。配对成功后可验证手机独立读树与操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("首次准备：发起系统配对") { experiment.preparePairing() }
                        .disabled(experiment.isRunning)
                    Button("启动一次读树与点击验证") { experiment.start() }
                        .disabled(experiment.isRunning)
                    if experiment.isRunning { Button("停止本次验证", role: .destructive) { experiment.stop() } }
                    ForEach(Array(experiment.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("本机验证")
            .task {
                if ProcessInfo.processInfo.arguments.contains("--probe-network") { await model.checkRoutes() }
                if ProcessInfo.processInfo.arguments.contains("--probe-control") { experiment.start() }
                if ProcessInfo.processInfo.arguments.contains("--prepare-pairing") { experiment.preparePairing() }
            }
        }
    }
}

// A serial queue owns both completion paths; cancellation and timeout cannot resume twice.
private final class TCPProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.amber.selfcontrol.route-probe")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Never>?
    private var timer: DispatchWorkItem?

    private init(host: String, port: UInt16) {
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
    }

    static func connect(host: String, port: UInt16) async -> String {
        let probe = TCPProbe(host: host, port: port)
        return await withCheckedContinuation { continuation in
            probe.queue.async {
                probe.continuation = continuation
                probe.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: probe.finish("可连接")
                    case .failed(let error): probe.finish("失败：\(error)")
                    default: break
                    }
                }
                let timer = DispatchWorkItem { probe.finish("5 秒内未连接") }
                probe.timer = timer
                probe.queue.asyncAfter(deadline: .now() + 5, execute: timer)
                probe.connection.start(queue: probe.queue)
            }
        }
    }

    private func finish(_ result: String) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
