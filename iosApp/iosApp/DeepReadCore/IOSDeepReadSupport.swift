import Foundation

enum IOSDeepReadClock {
    static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

enum IOSDeepReadDateFormatters {
    static let detail: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

extension String {
    var deepReadIfBlankNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deepReadIfEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    func deepReadPrefixString(_ limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
