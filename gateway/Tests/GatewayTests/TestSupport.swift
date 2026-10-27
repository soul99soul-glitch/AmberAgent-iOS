import Foundation
import GatewayCore
import Testing

enum TestSupport {
    /// The built `amber-gateway` executable lives in the products dir, somewhere above the resource bundle.
    static func binary() throws -> URL {
        var dir = Bundle.module.bundleURL
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("amber-gateway")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
                return candidate
            }
        }
        Issue.record("amber-gateway executable not found above \(Bundle.module.bundleURL.path); run `swift build` first")
        throw CancellationError()
    }

    /// Short path: sockaddr_un caps socket paths at 104 bytes.
    static func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/agw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var seconds: Double
    }

    @discardableResult
    static func run(_ executable: URL, _ args: [String], stateDir: URL, stdin: Data = Data()) throws -> Result {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging([GatewayPaths.stateDirEnv: stateDir.path]) { $1 }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let start = Date()
        try p.run()
        inPipe.fileHandleForWriting.write(stdin)
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: out, stderr: err, seconds: Date().timeIntervalSince(start))
    }

    static func spooled(_ stateDir: URL) -> [GatewayEvent] {
        var events: [GatewayEvent] = []
        Spool(dir: GatewayPaths(stateDir: stateDir).spoolDir).drain { events.append($0) }
        return events
    }

    static func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    /// Lets the kernel pick an unused TCP port so test daemons never collide with a real one on 47821.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// A copy of bash named after an agent, so the hook's process-tree walk sees a real "codex"/"claude".
    /// Not /bin/sh: on macOS it is a trampoline that re-execs bash, which would rename the process.
    /// Copied platform binaries are SIGKILLed on launch unless re-signed.
    static func fakeAgent(named name: String, in dir: URL) throws -> URL {
        try fakeAgent(at: "bin/\(name)", in: dir)
    }

    static func fakeAgent(at relativePath: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/bash"), to: url)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["-f", "-s", "-", url.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            try #require(sign.terminationStatus == 0, "codesign failed")
        }
        return url
    }
}
