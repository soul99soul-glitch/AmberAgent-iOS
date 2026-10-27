import Foundation

public struct HealthSnapshot: Codable, Sendable, Equatable {
    public enum MemoryPressure: String, Codable, Sendable { case normal, warning, critical }
    public enum Thermal: String, Codable, Sendable { case nominal, fair, serious, critical }

    public var sampledAt: Date
    public var diskFreeBytes: Int64?
    /// nil on machines without a battery.
    public var batteryPercent: Int?
    public var onBattery: Bool?
    public var memoryPressure: MemoryPressure
    public var thermal: Thermal

    public init(sampledAt: Date, diskFreeBytes: Int64?, batteryPercent: Int?, onBattery: Bool?, memoryPressure: MemoryPressure, thermal: Thermal) {
        self.sampledAt = sampledAt
        self.diskFreeBytes = diskFreeBytes
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.memoryPressure = memoryPressure
        self.thermal = thermal
    }
}

/// Threshold checks for the 60s heartbeat (design doc section 6). Alerts fire on entering a bad state
/// only; recovering clears the alert silently so a flapping metric can't spam.
public enum HealthPolicy {
    public static func problems(_ s: HealthSnapshot, config: GatewayConfig) -> [String: String] {
        var result: [String: String] = [:]
        if let free = s.diskFreeBytes, Double(free) < config.diskFreeThresholdGB * 1_000_000_000 {
            result["disk"] = String(format: "磁盘剩余 %.0f GB", Double(free) / 1_000_000_000)
        }
        if let percent = s.batteryPercent, s.onBattery == true, percent < config.batteryThresholdPercent {
            result["battery"] = "电量 \(percent)%，未接电源"
        }
        if s.memoryPressure == .critical {
            result["memory"] = "内存压力严重"
        }
        if s.thermal == .serious || s.thermal == .critical {
            result["thermal"] = s.thermal == .critical ? "温度过高（严重）" : "温度过高"
        }
        return result
    }
}
