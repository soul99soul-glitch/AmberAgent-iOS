import Foundation
import os

/// Samples independently of the main run loop. Per-round peaks are sampled;
/// the kernel's high-water mark is explicitly process-lifetime, not per-round.
final class ChatReplayMemoryProbe: @unchecked Sendable {
    struct Reading: Sendable {
        let footprint: UInt64
        let resident: UInt64
        let lifetimePeakFootprint: Int64
    }

    private struct State: Sendable {
        var peakFootprint: UInt64 = 0
        var peakResident: UInt64 = 0
        var samples = 0
        var failures = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "amber.perf.memory", qos: .utility)
    private var timer: DispatchSourceTimer?

    static func read() -> Reading? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Reading(footprint: info.phys_footprint, resident: info.resident_size,
                       lifetimePeakFootprint: info.ledger_phys_footprint_peak)
    }

    func start() {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func stop() -> [String: Any] {
        timer?.cancel()
        timer = nil
        queue.sync { sample() }
        let snapshot = state.withLock { $0 }
        return ["sampledPeakFootprintBytes": snapshot.peakFootprint,
                "sampledPeakResidentBytes": snapshot.peakResident,
                "memorySampleCount": snapshot.samples, "memorySampleFailures": snapshot.failures,
                "memorySamplePeriodMs": 10]
    }

    private func sample() {
        let reading = Self.read()
        state.withLock {
            guard let reading else { $0.failures += 1; return }
            $0.samples += 1
            $0.peakFootprint = max($0.peakFootprint, reading.footprint)
            $0.peakResident = max($0.peakResident, reading.resident)
        }
    }
}
