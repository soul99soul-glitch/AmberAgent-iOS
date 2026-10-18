import Foundation

/// Serializes only approval presentation for concurrent nested exec calls.
/// A released waiter inherits the occupied turn before a new caller may enter.
@MainActor
final class ChatNestedApprovalQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withTurn<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return await body()
    }
}
