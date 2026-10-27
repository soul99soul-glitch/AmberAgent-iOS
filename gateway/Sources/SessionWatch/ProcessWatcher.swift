import Darwin
import Foundation
import GatewayCore

/// kqueue `EVFILT_PROC`/`NOTE_EXIT` on arbitrary (non-child) processes. Exit status is not available for
/// non-children, so this only reports "gone". All methods must be called on `queue`.
public final class ProcessWatcher {
    private let queue: DispatchQueue
    private let currentIdentity: (Int32) -> ProcessIdentity?
    private let onExit: (ProcessIdentity) -> Void
    private let kq: Int32
    private var source: DispatchSourceRead?
    private var watched: [Int32: ProcessIdentity] = [:]

    public init(
        queue: DispatchQueue,
        currentIdentity: @escaping (Int32) -> ProcessIdentity?,
        onExit: @escaping (ProcessIdentity) -> Void
    ) {
        self.queue = queue
        self.currentIdentity = currentIdentity
        self.onExit = onExit
        kq = kqueue()
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
        close(kq)
    }

    public var watchedCount: Int { watched.count }

    public func watch(_ id: ProcessIdentity) {
        if watched[id.pid] == id { return }
        // (pid, start time) must still match, otherwise the PID now belongs to someone else.
        guard currentIdentity(id.pid) == id else { return reportGone(id) }

        var change = kevent(ident: UInt(id.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        if kevent(kq, &change, 1, nil, 0, nil) < 0 {
            return reportGone(id) // ESRCH: exited before we could register
        }
        // Closes the window where the process died and its PID was recycled between the check and EV_ADD.
        guard currentIdentity(id.pid) == id else {
            change.flags = UInt16(EV_DELETE)
            _ = kevent(kq, &change, 1, nil, 0, nil)
            return reportGone(id)
        }
        watched[id.pid] = id
    }

    private func reportGone(_ id: ProcessIdentity) {
        queue.async { [onExit] in onExit(id) }
    }

    private func drain() {
        var events = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 16)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let n = kevent(kq, nil, 0, &events, Int32(events.count), &zero)
            guard n > 0 else { return }
            for event in events[0..<Int(n)] {
                if let id = watched.removeValue(forKey: Int32(event.ident)) {
                    onExit(id)
                }
            }
        }
    }
}
