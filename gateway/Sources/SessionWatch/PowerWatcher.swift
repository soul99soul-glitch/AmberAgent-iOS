import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep notifications via IOKit (not NSWorkspace, which would pull AppKit into the daemon).
/// `onWillSleep` gets a completion; sleep is held until it is called or the system's own timeout expires.
public final class PowerWatcher {
    // kIOMessageCanSystemSleep / kIOMessageSystemWillSleep are C macros that Swift does not import.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    fileprivate var rootPort: io_connect_t = 0
    fileprivate let onWillSleep: (@escaping () -> Void) -> Void

    public init(queue: DispatchQueue, onWillSleep: @escaping (@escaping () -> Void) -> Void) {
        self.onWillSleep = onWillSleep
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.handle(messageType: messageType, argument: argument)
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, queue) }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if rootPort != 0 { IOServiceClose(rootPort) }
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            let root = rootPort
            var allowed = false
            onWillSleep {
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(root, token)
            }
        default:
            break
        }
    }
}

/// Idle-sleep assertion held while headless tasks run (design doc 6, mitigation 2).
public final class IdleSleepAssertion {
    private var id: IOPMAssertionID = 0

    public init() {}

    public func set(_ held: Bool) {
        if held, id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Amber Gateway: headless task running" as CFString, &id)
        } else if !held, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}
