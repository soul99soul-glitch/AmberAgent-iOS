import Darwin
import Foundation
import os
import QuartzCore
import SwiftStreamingMarkdown
import UIKit

/// Opt-in counters for the production timeline replay; no observed state or log traffic.
enum ChatRenderProbe {
    #if DEBUG
    private struct ActiveScene {
        var startWall: CFTimeInterval
        var startCpuNs: UInt64
        var expiresAtWall: CFTimeInterval
    }

    private struct State {
        var enabled = false
        var counts: [String: [String: Int]] = [:]
        var frameDeltas: [String: Int] = [:]
        var activeScenes: [String: ActiveScene] = [:]
    }
    // Layout callbacks are nonisolated. Keep measurement synchronous without
    // assuming a main-actor executor or adding tasks to the render workload.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }
    static var counts: [String: [String: Int]] { state.withLock { $0.counts } }

    static func reset() {
        state.withLock {
            $0.counts.removeAll(keepingCapacity: true)
            $0.frameDeltas.removeAll(keepingCapacity: true)
            $0.activeScenes.removeAll(keepingCapacity: true)
        }
    }

    static func drainFrameDeltas() -> [String: Int] {
        var drained: [String: Int] = [:]
        drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime())
        return drained
    }

    static func drainFrameDeltas(into target: inout [String: Int], nowWall: CFTimeInterval) {
        target.removeAll(keepingCapacity: true)
        state.withLockUnchecked { state in
            if !state.frameDeltas.isEmpty {
                for (key, value) in state.frameDeltas {
                    target[key] = value
                }
                state.frameDeltas.removeAll(keepingCapacity: true)
            }
            if !state.activeScenes.isEmpty {
                var expiredKeys: [String] = []
                for (name, scene) in state.activeScenes {
                    if nowWall <= scene.expiresAtWall {
                        target["scene:\(name)"] = 1
                    } else {
                        expiredKeys.append(name)
                    }
                }
                for key in expiredKeys {
                    state.activeScenes.removeValue(forKey: key)
                }
            }
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

    @inline(__always)
    static func add(_ scope: String, _ delta: Int, id: String = "all") {
        #if DEBUG
        guard delta > 0 else { return }
        state.withLock {
            guard $0.enabled else { return }
            $0.counts[scope, default: [:]][id, default: 0] += delta
            $0.frameDeltas[scope, default: 0] += delta
        }
        #endif
    }

    @inline(__always)
    static func measureUs<T>(_ scope: String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        guard enabled else { return try body() }
        let startWall = CACurrentMediaTime()
        defer {
            let elapsedUs = max(1, Int(((CACurrentMediaTime() - startWall) * 1_000_000.0).rounded()))
            add(scope, elapsedUs)
        }
        return try body()
        #else
        return try body()
        #endif
    }

    @inline(__always)
    static func beginScene(_ name: String, ttlSeconds: CFTimeInterval = 2.0, restart: Bool = true) {
        #if DEBUG
        state.withLock {
            guard $0.enabled else { return }
            let nowWall = CACurrentMediaTime()
            let nowCpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            if !restart, var existing = $0.activeScenes[name], nowWall <= existing.expiresAtWall {
                existing.expiresAtWall = max(existing.expiresAtWall, nowWall + ttlSeconds)
                $0.activeScenes[name] = existing
            } else {
                $0.activeScenes[name] = ActiveScene(
                    startWall: nowWall,
                    startCpuNs: nowCpuNs,
                    expiresAtWall: nowWall + ttlSeconds
                )
            }
            $0.frameDeltas["scene:\(name)"] = 1
        }
        #endif
    }

    @inline(__always)
    static func touchScene(_ name: String, ttlSeconds: CFTimeInterval = 2.0) {
        #if DEBUG
        state.withLock {
            guard $0.enabled, var existing = $0.activeScenes[name] else { return }
            let nowWall = CACurrentMediaTime()
            existing.expiresAtWall = nowWall + ttlSeconds
            $0.activeScenes[name] = existing
            $0.frameDeltas["scene:\(name)"] = 1
        }
        #endif
    }

    @discardableResult
    @inline(__always)
    static func endScene(_ name: String, spanKey: String? = nil, cpuKey: String? = nil) -> Bool {
        #if DEBUG
        return state.withLock {
            guard $0.enabled, let scene = $0.activeScenes.removeValue(forKey: name) else { return false }
            let nowWall = CACurrentMediaTime()
            let nowCpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            $0.frameDeltas["scene:\(name)"] = 1
            if let spanKey {
                let wallMs = max(1, Int(((nowWall - scene.startWall) * 1000.0).rounded()))
                $0.counts[spanKey, default: [:]]["all", default: 0] += wallMs
                $0.frameDeltas[spanKey, default: 0] += wallMs
            }
            if let cpuKey {
                let cpuMs = max(0, Int((Double(nowCpuNs &- scene.startCpuNs) / 1_000_000.0).rounded()))
                if cpuMs > 0 {
                    $0.counts[cpuKey, default: [:]]["all", default: 0] += cpuMs
                    $0.frameDeltas[cpuKey, default: 0] += cpuMs
                }
            }
            return true
        }
        #else
        return false
        #endif
    }
}

enum ChatPanelSwitchPerfProbe {
    #if DEBUG
    @MainActor private static var settleGeneration: UInt64 = 0
    #endif

    @MainActor
    @inline(__always)
    static func didSwitch(from oldRawValue: String, to newRawValue: String) {
        #if DEBUG
        guard ChatRenderProbe.enabled, oldRawValue != newRawValue else { return }
        settleGeneration &+= 1
        let token = settleGeneration
        let startWall = CACurrentMediaTime()
        let startCpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        ChatRenderProbe.record("panel-switch:start")
        ChatRenderProbe.record("panel:\(oldRawValue)->\(newRawValue)")
        ChatRenderProbe.beginScene("panel-switch", ttlSeconds: 2.0)

        DispatchQueue.main.async {
            guard ChatRenderProbe.enabled else { return }
            let commitWallMs = max(1, Int(((CACurrentMediaTime() - startWall) * 1000.0).rounded()))
            let commitCpuMs = max(
                0,
                Int((Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- startCpuNs) / 1_000_000.0).rounded())
            )
            ChatRenderProbe.add("ms:panel-first-commit", commitWallMs)
            ChatRenderProbe.add("ms:panel-first-commit-cpu", commitCpuMs)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard settleGeneration == token else { return }
            if ChatRenderProbe.endScene(
                "panel-switch",
                spanKey: "ms:panel-switch-span",
                cpuKey: "ms:panel-switch-cpu"
            ) {
                ChatRenderProbe.record("panel-switch:end")
            }
        }
        #endif
    }
}

#if DEBUG
@MainActor
final class AmberLivePerfFlightRecorder: NSObject {
    static let shared = AmberLivePerfFlightRecorder()
    nonisolated static let frameBudget120HzMs: Double = 1000.0 / 120.0
    nonisolated static let missedFrameThreshold120HzMs: Double = 12.5
    @available(iOS 15.0, *)
    nonisolated static var preferredFrameRateRange120Hz: CAFrameRateRange {
        CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
    }

    struct FrameBudgetMetrics: Equatable, Sendable {
        var overBudgetMs: Double = 0
        var stalledMs: Double = 0
        var drop12: Int = 0

        mutating func record(dtMs: Double) {
            let excess = dtMs - AmberLivePerfFlightRecorder.frameBudget120HzMs
            if excess > 0 {
                overBudgetMs += excess
            }
            if dtMs > AmberLivePerfFlightRecorder.missedFrameThreshold120HzMs {
                drop12 += 1
                if excess > 0 {
                    stalledMs += excess
                }
            }
        }

        mutating func reset() {
            overBudgetMs = 0
            stalledMs = 0
            drop12 = 0
        }
    }

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

    var displayLinkRateRangeForTesting: CAFrameRateRange? {
        displayLink?.preferredFrameRateRange
    }

    private var lastFrameWallTime: CFTimeInterval = 0
    private var lastFrameCpuNs: UInt64 = 0

    private var currentFrameProbes: [String: Int] = [:]
    private var windowStartWallTime: CFTimeInterval = 0
    private var windowProbes: [String: Int] = [:]
    private var windowDtSamples: [Double] = []
    private var windowCpuTotalMs: Double = 0
    private var windowCpuMaxMs: Double = 0
    private var windowBudgetMetrics = FrameBudgetMetrics()
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
            "commit": "76676f78+probes-v2",
            "probeSchema": 2,
            "bundleId": Bundle.main.bundleIdentifier ?? "app.amber.ios",
            "file": fileURL.path
        ]
        let startupLine = Self.encodeJSONLine(startupPayload)
        logger.notice("[PerfFlight] startup pid=\(pid, privacy: .public) file=\(fileURL.path, privacy: .public)")

        ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: prevURL)
                try? fm.moveItem(at: fileURL, to: prevURL)
            }
            let initialData = ((startupLine ?? "{\"type\":\"startup\"}") + "\n").data(using: .utf8) ?? Data()
            fm.createFile(atPath: fileURL.path, contents: initialData)
        }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardDidShow),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        currentFrameProbes.reserveCapacity(32)
        windowProbes.reserveCapacity(48)
        windowDtSamples.reserveCapacity(140)
        ChatRenderProbe.drainFrameDeltas(into: &currentFrameProbes, nowWall: CACurrentMediaTime())
        currentFrameProbes.removeAll(keepingCapacity: true)

        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = Self.preferredFrameRateRange120Hz
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

    @objc private func handleKeyboardWillShow() {
        ChatRenderProbe.record("keyboard:will-show")
        ChatRenderProbe.beginScene("keyboard-show", ttlSeconds: 2.5, restart: false)
    }

    @objc private func handleKeyboardDidShow() {
        if ChatRenderProbe.endScene(
            "keyboard-show",
            spanKey: "ms:keyboard-show-span",
            cpuKey: "ms:keyboard-show-cpu"
        ) {
            ChatRenderProbe.record("keyboard:did-show")
        }
    }

    @objc private func handleKeyboardWillHide() {
        ChatRenderProbe.record("keyboard:will-hide")
        ChatRenderProbe.beginScene("keyboard-hide", ttlSeconds: 2.5, restart: false)
    }

    @objc private func handleKeyboardDidHide() {
        if ChatRenderProbe.endScene(
            "keyboard-hide",
            spanKey: "ms:keyboard-hide-span",
            cpuKey: "ms:keyboard-hide-cpu"
        ) {
            ChatRenderProbe.record("keyboard:did-hide")
        }
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let nowWall = CACurrentMediaTime()
        let nowCpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        ChatRenderProbe.drainFrameDeltas(into: &currentFrameProbes, nowWall: nowWall)

        guard lastFrameWallTime > 0 else {
            lastFrameWallTime = nowWall
            lastFrameCpuNs = nowCpuNs
            windowStartWallTime = nowWall
            if !currentFrameProbes.isEmpty {
                for (key, value) in currentFrameProbes {
                    windowProbes[key, default: 0] += value
                }
            }
            return
        }

        let dtMs = max(0, (nowWall - lastFrameWallTime) * 1000.0)
        let cpuMs = Double(nowCpuNs &- lastFrameCpuNs) / 1_000_000.0

        lastFrameWallTime = nowWall
        lastFrameCpuNs = nowCpuNs
        if !currentFrameProbes.isEmpty {
            for (key, value) in currentFrameProbes {
                windowProbes[key, default: 0] += value
            }
        }

        windowDtSamples.append(dtMs)
        windowCpuTotalMs += cpuMs
        if cpuMs > windowCpuMaxMs {
            windowCpuMaxMs = cpuMs
        }
        windowBudgetMetrics.record(dtMs: dtMs)
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
                "probes": currentFrameProbes
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
            let overBudgetRounded = Self.round2(windowBudgetMetrics.overBudgetMs)
            let stalledRounded = Self.round2(windowBudgetMetrics.stalledMs)
            let drop12Count = windowBudgetMetrics.drop12
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
                "overBudgetMs": overBudgetRounded,
                "stalledMs": stalledRounded,
                "drop12": drop12Count,
                "drop24": drop24Count,
                "drop50": windowDrop50,
                "drop100": windowDrop100,
                "hitches": windowHitchCount,
                "probes": currentWindowProbes
            ]
            if let line = Self.encodeJSONLine(summaryPayload) {
                pendingLines.append(line)
                if !currentWindowProbes.isEmpty || drop12Count > 0 || drop24Count > 0 || windowHitchCount > 0 {
                    logger.info("[PerfFlight] 1s fps=\(fpsRounded, privacy: .public) maxDt=\(maxDtRounded, privacy: .public) stalledMs=\(stalledRounded, privacy: .public) cpu=\(cpuTotalRounded, privacy: .public) drop24=\(drop24Count, privacy: .public) line=\(line, privacy: .public)")
                }
            }

            windowStartWallTime = nowWall
            windowProbes.removeAll(keepingCapacity: true)
            windowDtSamples.removeAll(keepingCapacity: true)
            windowCpuTotalMs = 0
            windowCpuMaxMs = 0
            windowBudgetMetrics.reset()
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
