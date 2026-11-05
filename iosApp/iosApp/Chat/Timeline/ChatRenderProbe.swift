import Foundation
import os

/// Opt-in counters for the production timeline replay; no observed state or log traffic.
enum ChatRenderProbe {
    #if DEBUG
    private struct State {
        var enabled = false
        var counts: [String: [String: Int]] = [:]
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
    #endif

    @inline(__always)
    static func record(_ scope: String, id: String = "all") {
        #if DEBUG
        state.withLock {
            guard $0.enabled else { return }
            $0.counts[scope, default: [:]][id, default: 0] += 1
        }
        #endif
    }
}
