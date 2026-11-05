import Foundation

/// Opt-in counters for the production timeline replay; no observed state or log traffic.
@MainActor
enum ChatRenderProbe {
    #if DEBUG
    static var enabled = false
    static private(set) var counts: [String: [String: Int]] = [:]

    static func reset() { counts = [:] }
    #endif

    @inline(__always)
    static func record(_ scope: String, id: String = "all") {
        #if DEBUG
        guard enabled else { return }
        counts[scope, default: [:]][id, default: 0] += 1
        #endif
    }
}
