import Foundation

final class IOSAmberShellExecutionControl: @unchecked Sendable {
    let opaquePointer: OpaquePointer

    init(timeoutSeconds: TimeInterval) throws {
        guard let pointer = amber_shell_execution_control_create(timeoutSeconds) else {
            throw IOSAmberShellExecutionControlError.unavailable
        }
        opaquePointer = pointer
    }

    deinit {
        amber_shell_execution_control_destroy(opaquePointer)
    }

    func cancel() {
        _ = amber_shell_execution_control_cancel(opaquePointer)
    }

    func checkpoint() throws {
        switch amber_shell_execution_control_checkpoint(opaquePointer) {
        case AmberShellExecutionStateCancelled:
            throw IOSAmberShellTermination.cancelled
        case AmberShellExecutionStateTimedOut:
            throw IOSAmberShellTermination.timedOut
        case AmberShellExecutionStateRunning:
            break
        default:
            throw IOSAmberShellExecutionControlError.invalidState
        }
    }
}

private enum IOSAmberShellExecutionControlError: LocalizedError {
    case unavailable
    case invalidState

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Unable to create AmberShell execution control."
        case .invalidState:
            "AmberShell execution control returned an invalid state."
        }
    }
}
