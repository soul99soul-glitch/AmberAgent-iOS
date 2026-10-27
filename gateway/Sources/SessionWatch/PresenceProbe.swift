import CoreGraphics
import Foundation
import GatewayCore
import IOKit

/// Is the user at the Mac? Sampled on demand only (no polling unless a push is being held back).
public enum PresenceProbe {
    public static func current() -> Presence {
        Presence(screenLocked: screenLocked(), idleSeconds: hidIdleSeconds())
    }

    static func hidIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return 0 }
        return Double(value.uint64Value) / 1_000_000_000
    }

    static func screenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
