import Foundation
import Darwin

struct DesktopCommandResult: Equatable, Sendable {
    let output: String
    let exitCode: Int32
    let truncated: Bool
    let timedOut: Bool
    let cancelled: Bool
}

enum DesktopCommandRunner {
    static func run(_ command: String, directory: URL, timeout: Duration = .seconds(30)) async throws -> DesktopCommandResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("命令不能为空。")
        }
        let execution = Execution()
        let deadline = Task {
            do { try await Task.sleep(for: timeout); execution.stop(timedOut: true) }
            catch {}
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execution.execute(command, directory: directory)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { execution.stop(timedOut: false) }
    }

    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private var processID: pid_t = 0
        private var running = false
        private var stopped = false
        private var timedOut = false

        func stop(timedOut: Bool) {
            lock.lock()
            stopped = true
            self.timedOut = self.timedOut || timedOut
            if running { kill(-processID, SIGTERM) }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if running { kill(-processID, SIGKILL) }
                lock.unlock()
            }
        }

        func execute(_ command: String, directory: URL) throws -> DesktopCommandResult {
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else { throw failure("无法创建命令输出管道。") }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&actions, descriptors[0])
            posix_spawn_file_actions_addclose(&actions, descriptors[1])
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            let chdirError = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            guard chdirError == 0 else {
                close(descriptors[0]); close(descriptors[1]); throw failure("无法进入会话工作区。")
            }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
            // App runs already have a QoS; zsh's background nice() is unnecessary here.
            var arguments = ["/bin/zsh", "-o", "NO_BGNICE", "-c", command].map { strdup($0) } + [nil]
            let environmentStrings: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
            environment.append(nil)
            defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
            var child: pid_t = 0
            lock.lock()
            if stopped {
                let timeout = timedOut
                lock.unlock()
                close(descriptors[0]); close(descriptors[1])
                return DesktopCommandResult(output: "", exitCode: -1, truncated: false, timedOut: timeout, cancelled: !timeout)
            }
            let spawnError = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &arguments, &environment)
            processID = child
            running = spawnError == 0
            lock.unlock()
            close(descriptors[1])
            guard spawnError == 0 else { close(descriptors[0]); throw failure("系统拒绝执行命令（\(spawnError)）。") }
            // Drain concurrently so a child with a full stdout pipe can always exit.
            let output = Output()
            let group = DispatchGroup()
            group.enter()
            let readFD = descriptors[0]
            DispatchQueue.global(qos: .utility).async {
                defer { close(readFD); group.leave() }
                var bytes = [UInt8](repeating: 0, count: 8192)
                while true {
                    let size = read(readFD, &bytes, bytes.count)
                    if size > 0 { output.append(Data(bytes.prefix(size))) }
                    else if size < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            lock.lock()
            running = false
            let wasStopped = stopped
            let timeout = timedOut
            // A background descendant may retain the pipe after its shell exits.
            kill(-child, SIGKILL)
            lock.unlock()
            group.wait()
            let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return DesktopCommandResult(output: String(decoding: output.data, as: UTF8.self), exitCode: exitCode,
                truncated: output.truncated, timedOut: timeout, cancelled: wasStopped && !timeout)
        }

        private func failure(_ text: String) -> DesktopRuntimeError { .message(text) }
    }

    private final class Output: @unchecked Sendable {
        var data = Data()
        var truncated = false
        func append(_ bytes: Data) {
            let remaining = max(0, 65_536 - data.count)
            data.append(bytes.prefix(remaining))
            if bytes.count > remaining { truncated = true }
        }
    }
}
