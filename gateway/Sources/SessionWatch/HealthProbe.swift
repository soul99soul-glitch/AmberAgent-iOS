import Foundation
import GatewayCore
import IOKit.ps

public enum HealthProbe {
    /// Memory pressure is event-driven (DispatchSource), so the daemon tracks it and passes it in.
    public static func sample(memoryPressure: HealthSnapshot.MemoryPressure, now: Date = Date()) -> HealthSnapshot {
        let battery = batteryState()
        return HealthSnapshot(
            sampledAt: now,
            diskFreeBytes: diskFreeBytes(),
            batteryPercent: battery?.percent,
            onBattery: battery?.onBattery,
            memoryPressure: memoryPressure,
            thermal: thermal()
        )
    }

    static func diskFreeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func batteryState() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onBattery = desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / max, onBattery)
        }
        return nil
    }

    static func thermal() -> HealthSnapshot.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
