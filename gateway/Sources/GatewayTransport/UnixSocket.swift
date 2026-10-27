import Darwin
import Foundation

enum UnixAddress {
    static func make(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// One-shot sender used by short-lived hook processes: connect, write, half-close, wait for "ok".
/// Everything shares one deadline; any failure returns false so the caller can spool instead.
public enum UnixSocketClient {
    public static let ack = Data("ok\n".utf8)

    public static func send(_ payload: Data, to path: String, timeout: TimeInterval) -> Bool {
        request(payload, to: path, timeout: timeout, maxResponse: ack.count) == ack
    }

    /// Request/response over one connection: write, half-close, read until the peer closes (or `maxResponse`).
    /// nil on connect failure, timeout or an empty reply.
    public static func request(_ payload: Data, to path: String, timeout: TimeInterval, maxResponse: Int = UnixSocketServer.maxMessageSize) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        guard var addr = UnixAddress.make(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN, wait(fd, events: Int16(POLLOUT), until: deadline) else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }

        var offset = 0
        while offset < payload.count {
            let n = payload.withUnsafeBytes { write(fd, $0.baseAddress! + offset, payload.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EAGAIN {
                guard wait(fd, events: Int16(POLLOUT), until: deadline) else { return nil }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, maxResponse))
        while response.count < maxResponse {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                response.append(contentsOf: buffer[0..<n])
            } else if n < 0 && errno == EAGAIN {
                guard wait(fd, events: Int16(POLLIN), until: deadline) else { return nil }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return response.isEmpty ? nil : response
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0 else { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let rc = poll(&pfd, 1, remaining)
            if rc > 0 { return true }
            if rc == 0 { return false }
            if errno != EINTR { return false }
        }
    }
}

/// Accepts one message per connection (client half-closes), passes it to `handler` and acks when the
/// handler accepts it. Runs entirely on `queue`. With `respond`, the handler's reply is written instead of the
/// ack (request/response channel, e.g. the Amber app's control socket).
public final class UnixSocketServer {
    public static let maxMessageSize = 64 * 1024

    private let path: String
    private let queue: DispatchQueue
    private let handler: (Data) -> Data?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Inode of the socket file this server bound; `stop` only unlinks the path if it is still ours, so a
    /// server that took the path over afterwards keeps its socket.
    private var boundInode: ino_t = 0

    public init(path: String, queue: DispatchQueue, handler: @escaping (Data) -> Bool) {
        self.path = path
        self.queue = queue
        self.handler = { handler($0) ? UnixSocketClient.ack : nil }
    }

    public init(path: String, queue: DispatchQueue, respond: @escaping (Data) -> Data?) {
        self.path = path
        self.queue = queue
        self.handler = respond
    }

    public func start() throws {
        guard var addr = UnixAddress.make(path) else { throw POSIXError(.ENAMETOOLONG) }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        if stat(path, &info) == 0 { boundInode = info.st_ino }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        if isBound { unlink(path) }
        boundInode = 0
    }

    /// The path still names the socket this server bound (another process may have replaced or removed it).
    public var isBound: Bool {
        var info = stat()
        return boundInode != 0 && stat(path, &info) == 0 && info.st_ino == boundInode
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        // A stalled local client must not wedge the daemon queue.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var message = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while message.count <= Self.maxMessageSize {
            let n = read(client, &buffer, buffer.count)
            if n > 0 {
                message.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
        guard message.count <= Self.maxMessageSize, let reply = handler(message) else { return }
        var offset = 0
        while offset < reply.count {
            let n = reply.withUnsafeBytes { write(client, $0.baseAddress! + offset, reply.count - offset) }
            guard n > 0 else { return }
            offset += n
        }
    }
}
