import Foundation
import os

/// Sparse, opt-in signposts for the chat pipeline. The trace never records message
/// contents or identifiers, and it remains available in Release/Profile builds.
enum ChatPerfTrace {
    static let enabledDefaultsKey = "chat.perf.trace.enabled"
    static let subsystem = "app.amber.ios"
    static let category = "ChatPerformance"

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static let configuredEnabled: Bool = {
#if CHAT_PERF_REPLAY
        true
#else
        UserDefaults.standard.bool(forKey: enabledDefaultsKey) ||
            ProcessInfo.processInfo.arguments.contains("-ChatPerfTrace") ||
            ProcessInfo.processInfo.environment["AA_CHAT_PERF_TRACE"] == "1"
#endif
    }()

    static var isEnabled: Bool {
        configuredEnabled && signposter.isEnabled
    }

    static func begin(_ name: StaticString, count: Int = 0) -> Interval? {
        guard isEnabled else { return nil }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id, "count=\(count)")
        return Interval(name: name, state: state)
    }

    static func end(_ interval: inout Interval?) {
        guard let current = interval else { return }
        signposter.endInterval(current.name, current.state)
        interval = nil
    }

    static func event(_ name: StaticString, value: Int = 0) {
        guard isEnabled else { return }
        signposter.emitEvent(name, id: signposter.makeSignpostID(), "value=\(value)")
    }

    @discardableResult
    static func measure<T>(
        _ name: StaticString,
        count: () -> Int = { 0 },
        _ operation: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try operation() }
        var interval = begin(name, count: count())
        defer { end(&interval) }
        return try operation()
    }

    @discardableResult
    static func measure<T>(
        _ name: StaticString,
        count: () -> Int = { 0 },
        _ operation: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await operation() }
        var interval = begin(name, count: count())
        defer { end(&interval) }
        return try await operation()
    }
}
