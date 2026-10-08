import Foundation

enum IOSHotListClock {
    static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

extension String {
    func hotListIfEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    func hotListPrefixString(_ limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
