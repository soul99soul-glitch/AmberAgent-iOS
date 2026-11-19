import Foundation
import QuartzCore

/// CPU consumed on the main thread between display-link deliveries, not GPU
/// rendering time. The first interval starts at the event, so it is partial.
@MainActor
final class ChatReplayFrameCPUProbe: NSObject {
    private var link: CADisplayLink?
    private var previousCPU: UInt64 = 0
    private var previousWall: TimeInterval = 0
    private(set) var frames: [[String: Double]] = []

    func start() {
        previousCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        previousWall = ProcessInfo.processInfo.systemUptime
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        capture(terminal: true)
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        capture(terminal: false)
    }

    private func capture(terminal: Bool) {
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wall = ProcessInfo.processInfo.systemUptime
        frames.append([
            "endUptime": wall,
            "partialStart": frames.isEmpty ? 1 : 0,
            "partialEnd": terminal ? 1 : 0,
            "mainCPUMs": Double(cpu - previousCPU) / 1e6,
            "wallMs": (wall - previousWall) * 1000
        ])
        previousCPU = cpu
        previousWall = wall
    }
}
