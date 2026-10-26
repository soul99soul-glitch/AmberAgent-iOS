import Foundation
@preconcurrency import Shared

// Gemini's existing Foundation-only client uses the same local timestamps as iOS.
func chatNowLocalDateTime() -> Kotlinx_datetimeLocalDateTime {
    let now = Date()
    let calendar = Calendar.current
    return Kotlinx_datetimeLocalDateTime(
        year: Int32(calendar.component(.year, from: now)),
        month: Int32(calendar.component(.month, from: now)),
        day: Int32(calendar.component(.day, from: now)),
        hour: Int32(calendar.component(.hour, from: now)),
        minute: Int32(calendar.component(.minute, from: now)),
        second: Int32(calendar.component(.second, from: now)),
        nanosecond: Int32(calendar.component(.nanosecond, from: now)))
}
