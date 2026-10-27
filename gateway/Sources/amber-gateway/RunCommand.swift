import Darwin
import Foundation
import GatewayCore
import GatewayTransport
import HookIngest

/// `amber-gateway run -- <cmd>`: the only task source with a real exit status, because `run` is the
/// child's parent and can `waitpid` it (design doc 3.2).
enum RunCommand {
    static func run(_ args: [String]) -> Int32 {
        var command = args
        if command.first == "--" { command.removeFirst() }
        guard !command.isEmpty else {
            FileHandle.standardError.write(Data("用法: amber-gateway run -- <cmd> [args...]\n".utf8))
            return 64
        }

        let paths = GatewayPaths.resolve()
        let sessionId = "run-" + UUID().uuidString.prefix(8).lowercased()
        let title = (command[0] as NSString).lastPathComponent
        let cwd = FileManager.default.currentDirectoryPath
        func report(_ kind: EventKind, exitCode: Int32? = nil, signal: Int32? = nil) {
            EventDelivery.deliver(GatewayEvent(
                agent: .run, kind: kind, sessionId: sessionId, cwd: cwd,
                process: ProcessTree.identity(pid: getpid()), origin: .headless, title: title,
                exitCode: exitCode, signal: signal
            ), paths: paths)
        }

        report(.runStart)

        // The terminal delivers ^C/^\ to the whole foreground group; `run` must outlive the child to report it.
        let forwarded = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]
        for sig in forwarded { signal(sig, SIG_IGN) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in forwarded { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

        var child: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawnp(&child, command[0], nil, &attr, argv, environ)
        guard rc == 0 else {
            FileHandle.standardError.write(Data("amber-gateway run: \(command[0]): \(String(cString: strerror(rc)))\n".utf8))
            report(.runExit, exitCode: 127)
            return 127
        }

        let pid = child
        let signalSources = [SIGTERM, SIGHUP].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(pid, sig) }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}

        let termSignal = status & 0x7f
        if termSignal == 0 {
            let code = (status >> 8) & 0xff
            report(.runExit, exitCode: code)
            return code
        }
        report(.runExit, signal: termSignal)
        return 128 + termSignal
    }
}
