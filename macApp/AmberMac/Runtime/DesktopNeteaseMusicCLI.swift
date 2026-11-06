import Darwin
import Foundation

// Only the explicitly approved music operations are exposed to plugin views.
enum DesktopNeteaseMusicCLI {
    static func arguments(method: String, args: [Any]) throws -> [String] {
        switch method {
        case "state", "pause", "resume", "next", "prev":
            guard args.isEmpty else { throw DesktopRuntimeError.message("播放控制参数无效。") }
            return [method, "--output", "json"]
        case "search":
            guard args.count == 1, let raw = args[0] as? String else {
                throw DesktopRuntimeError.message("请输入歌曲或歌手名称。")
            }
            let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, keyword.count <= 120, !keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DesktopRuntimeError.message("搜索词须为 1–120 个非控制字符。")
            }
            return ["search", "song", "--keyword", keyword, "--userInput", "搜索歌曲：\(keyword)", "--output", "json"]
        case "play", "enqueue":
            guard args.count == 1, let track = args[0] as? [String: Any],
                  let encryptedID = track["encryptedId"] as? String,
                  let originalID = track["originalId"] as? String,
                  encryptedID.utf8.count == 32,
                  encryptedID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  (1...20).contains(originalID.utf8.count),
                  originalID.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw DesktopRuntimeError.message("歌曲 ID 无效，无法控制播放。")
            }
            let prefix = method == "play" ? ["play", "--song"] : ["queue", "add"]
            return prefix + ["--encrypted-id", encryptedID, "--original-id", originalID, "--output", "json"]
        default:
            throw DesktopRuntimeError.message("不支持的网易云音乐操作。")
        }
    }

    static func run(arguments: [String]) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let path = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        guard let executable = path.split(separator: ":").map({ String($0) + "/ncm-cli" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DesktopRuntimeError.message("未找到 ncm-cli。请先安装官方 @music163/ncm-cli，再完成 configure 和 login。")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-ncm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let stdoutURL = temporaryDirectory.appendingPathComponent("out")
        let stderrURL = temporaryDirectory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(["PATH": path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw DesktopRuntimeError.message("网易云音乐命令超时，请检查网络或播放器后重试。")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: stdoutURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 2_000_000 else { throw DesktopRuntimeError.message("网易云音乐返回的数据过大。") }
        let output = try Data(contentsOf: stdoutURL)
        if let value = try? JSONSerialization.jsonObject(with: output), JSONSerialization.isValidJSONObject(value) {
            guard process.terminationStatus == 0 || (value as? [String: Any])?["success"] as? Bool == false else {
                throw DesktopRuntimeError.message("网易云音乐命令执行失败，请检查配置、登录状态及 mpv。")
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let errorReader = try FileHandle(forReadingFrom: stderrURL)
        defer { try? errorReader.close() }
        let diagnostic = String(decoding: output.prefix(4096), as: UTF8.self)
            + String(decoding: (try? errorReader.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        if diagnostic.localizedCaseInsensitiveContains("API key") {
            throw DesktopRuntimeError.message("尚未配置网易云开放平台 API Key；请在终端运行 ncm-cli configure。")
        }
        if diagnostic.contains("登录") || diagnostic.contains("授权") {
            throw DesktopRuntimeError.message("网易云账号未登录或授权已过期；请在终端运行 ncm-cli login。")
        }
        throw DesktopRuntimeError.message("网易云音乐命令失败或返回格式无法识别，请检查 CLI 配置、登录状态及 mpv。")
    }
}
