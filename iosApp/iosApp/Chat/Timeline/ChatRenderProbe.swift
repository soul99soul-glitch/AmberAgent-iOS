import Darwin
import Foundation
import os
import QuartzCore
import SwiftStreamingMarkdown
import UIKit

/// Opt-in counters for the production timeline replay; no observed state or log traffic.
enum ChatRenderProbe {
    #if DEBUG
    private struct State {
        var enabled = false
        var counts: [String: [String: Int]] = [:]
        var frameDeltas: [String: Int] = [:]
    }
    // Layout callbacks are nonisolated. Keep measurement synchronous without
    // assuming a main-actor executor or adding tasks to the render workload.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }
    static var counts: [String: [String: Int]] { state.withLock { $0.counts } }

    static func reset() { state.withLock { $0.counts = [:] } }

    static func drainFrameDeltas() -> [String: Int] {
        state.withLock {
            guard !$0.frameDeltas.isEmpty else { return [:] }
            let drained = $0.frameDeltas
            $0.frameDeltas.removeAll(keepingCapacity: true)
            return drained
        }
    }
    #endif

    @inline(__always)
    static func record(_ scope: String, id: String = "all") {
        #if DEBUG
        state.withLock {
            guard $0.enabled else { return }
            $0.counts[scope, default: [:]][id, default: 0] += 1
            $0.frameDeltas[scope, default: 0] += 1
        }
        #endif
    }
}

#if DEBUG
@MainActor
final class AmberLivePerfFlightRecorder: NSObject {
    static let shared = AmberLivePerfFlightRecorder()

    private let logger = Logger(subsystem: "app.amber.ios", category: "PerfFlight")
    private let ioQueue = DispatchQueue(label: "app.amber.ios.perf-flight-io", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var isStarted = false
    private var displayLink: CADisplayLink?
    private var logFileURL: URL?

    private var lastFrameWallTime: CFTimeInterval = 0
    private var lastFrameCpuNs: UInt64 = 0

    private var windowStartWallTime: CFTimeInterval = 0
    private var windowProbes: [String: Int] = [:]
    private var windowDtSamples: [Double] = []
    private var windowCpuTotalMs: Double = 0
    private var windowCpuMaxMs: Double = 0
    private var windowDrop24 = 0
    private var windowDrop50 = 0
    private var windowDrop100 = 0
    private var windowHitchCount = 0

    private var pendingLines: [String] = []
    private var pendingHitchLinesCount = 0

    func start() {
        guard !isStarted else { return }
        isStarted = true
        ChatRenderProbe.enabled = true
        ParagraphUIViewLiveProbe.onRecord = { scope in
            ChatRenderProbe.record(scope)
        }

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsDir.appendingPathComponent("amber-perf-live.jsonl")
        let prevURL = documentsDir.appendingPathComponent("amber-perf-live.prev.jsonl")
        self.logFileURL = fileURL

        let nowDate = Date()
        let ts = isoFormatter.string(from: nowDate)
        let epochMs = Int64(nowDate.timeIntervalSince1970 * 1000.0)
        let pid = ProcessInfo.processInfo.processIdentifier
        let startupPayload: [String: Any] = [
            "type": "startup",
            "ts": ts,
            "epochMs": epochMs,
            "pid": pid,
            "commit": "fb78ace7",
            "bundleId": Bundle.main.bundleIdentifier ?? "app.amber.ios",
            "file": fileURL.path
        ]
        let startupLine = Self.encodeJSONLine(startupPayload)
        logger.notice("[PerfFlight] startup pid=\(pid, privacy: .public) file=\(fileURL.path, privacy: .public)")

        ioQueue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: prevURL)
                try? fm.moveItem(at: fileURL, to: prevURL)
            }
            let initialData = ((startupLine ?? "{\"type\":\"startup\"}") + "\n").data(using: .utf8) ?? Data()
            fm.createFile(atPath: fileURL.path, contents: initialData)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        _ = ChatRenderProbe.drainFrameDeltas()
        windowDtSamples.reserveCapacity(140)

        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func handleAppWillResignActive() {
        flushPendingLines()
    }

    @objc private func handleAppDidEnterBackground() {
        flushPendingLines()
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let nowWall = CACurrentMediaTime()
        let nowCpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let frameProbes = ChatRenderProbe.drainFrameDeltas()

        guard lastFrameWallTime > 0 else {
            lastFrameWallTime = nowWall
            lastFrameCpuNs = nowCpuNs
            windowStartWallTime = nowWall
            if !frameProbes.isEmpty {
                for (key, value) in frameProbes {
                    windowProbes[key, default: 0] += value
                }
            }
            return
        }

        let dtMs = max(0, (nowWall - lastFrameWallTime) * 1000.0)
        let cpuMs = Double(nowCpuNs &- lastFrameCpuNs) / 1_000_000.0

        lastFrameWallTime = nowWall
        lastFrameCpuNs = nowCpuNs
        if !frameProbes.isEmpty {
            for (key, value) in frameProbes {
                windowProbes[key, default: 0] += value
            }
        }

        windowDtSamples.append(dtMs)
        windowCpuTotalMs += cpuMs
        if cpuMs > windowCpuMaxMs {
            windowCpuMaxMs = cpuMs
        }
        if dtMs > 24.0 { windowDrop24 += 1 }
        if dtMs > 50.0 { windowDrop50 += 1 }
        if dtMs > 100.0 { windowDrop100 += 1 }

        if dtMs >= 32.0 || cpuMs >= 20.0 {
            windowHitchCount += 1
            let nowDate = Date()
            let hitchPayload: [String: Any] = [
                "type": "hitch",
                "ts": isoFormatter.string(from: nowDate),
                "epochMs": Int64(nowDate.timeIntervalSince1970 * 1000.0),
                "dtMs": Self.round2(dtMs),
                "cpuMs": Self.round2(cpuMs),
                "probes": frameProbes
            ]
            if let line = Self.encodeJSONLine(hitchPayload) {
                pendingLines.append(line)
                pendingHitchLinesCount += 1
                logger.warning("[PerfFlight] hitch dtMs=\(Self.round2(dtMs), privacy: .public) cpuMs=\(Self.round2(cpuMs), privacy: .public) probes=\(line, privacy: .public)")
                if pendingHitchLinesCount >= 6 {
                    flushPendingLines()
                }
            }
        }

        let windowElapsed = nowWall - windowStartWallTime
        if windowElapsed >= 1.0, !windowDtSamples.isEmpty {
            let sorted = windowDtSamples.sorted()
            let count = sorted.count
            let p50 = sorted[min(count - 1, count / 2)]
            let p95 = sorted[min(count - 1, Int(Double(count - 1) * 0.95))]
            let maxDt = sorted[count - 1]
            let fps = Double(count) / windowElapsed
            let nowDate = Date()
            let currentWindowProbes = windowProbes

            let fpsRounded = Self.round2(fps)
            let maxDtRounded = Self.round2(maxDt)
            let cpuTotalRounded = Self.round2(windowCpuTotalMs)
            let drop24Count = windowDrop24
            let summaryPayload: [String: Any] = [
                "type": "summary_1s",
                "ts": isoFormatter.string(from: nowDate),
                "epochMs": Int64(nowDate.timeIntervalSince1970 * 1000.0),
                "windowMs": Self.round2(windowElapsed * 1000.0),
                "frames": count,
                "fps": fpsRounded,
                "dtP50Ms": Self.round2(p50),
                "dtP95Ms": Self.round2(p95),
                "dtMaxMs": maxDtRounded,
                "cpuTotalMs": cpuTotalRounded,
                "cpuMaxMs": Self.round2(windowCpuMaxMs),
                "drop24": drop24Count,
                "drop50": windowDrop50,
                "drop100": windowDrop100,
                "hitches": windowHitchCount,
                "probes": currentWindowProbes
            ]
            if let line = Self.encodeJSONLine(summaryPayload) {
                pendingLines.append(line)
                if !currentWindowProbes.isEmpty || drop24Count > 0 || windowHitchCount > 0 {
                    logger.info("[PerfFlight] 1s fps=\(fpsRounded, privacy: .public) maxDt=\(maxDtRounded, privacy: .public) cpu=\(cpuTotalRounded, privacy: .public) drop24=\(drop24Count, privacy: .public) line=\(line, privacy: .public)")
                }
            }

            windowStartWallTime = nowWall
            windowProbes.removeAll(keepingCapacity: true)
            windowDtSamples.removeAll(keepingCapacity: true)
            windowCpuTotalMs = 0
            windowCpuMaxMs = 0
            windowDrop24 = 0
            windowDrop50 = 0
            windowDrop100 = 0
            windowHitchCount = 0

            flushPendingLines()
        }
    }

    private func flushPendingLines() {
        guard !pendingLines.isEmpty, let fileURL = logFileURL else { return }
        let linesToWrite = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        pendingHitchLinesCount = 0

        let payload = linesToWrite.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        ioQueue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private static func diffProbes(from previous: [String: Int], to current: [String: Int]) -> [String: Int] {
        var delta: [String: Int] = [:]
        for (key, value) in current {
            let old = previous[key] ?? 0
            if value > old {
                delta[key] = value - old
            }
        }
        return delta
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }

    private static func encodeJSONLine(_ dictionary: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
#endif
