#if canImport(AlarmKit)
import AlarmKit
import Foundation

struct IOSAmberAlarmMetadata: AlarmMetadata {
    let title: String
}

enum IOSAlarmCopy {
    static var defaultTitle: String { string("alarm.title", "Amber Alarm") }
    static var paused: String { string("alarm.state.paused", "Paused") }
    static var ringing: String { string("alarm.state.ringing", "Ringing") }
    static var countdown: String { string("alarm.state.countdown", "Countdown") }
    static var zeroTime: String { string("alarm.state.zero_time", "0:00") }

    static var approvalTitle: String { string("alarm.approval.title", "Confirm system alarm") }
    static var scheduleWarning: String {
        string(
            "alarm.approval.schedule_warning",
            "This is a system alarm that will sound and may override Silent or Focus. It is created only after approval."
        )
    }
    static var cancelWarning: String {
        string("alarm.approval.cancel_warning", "Approval immediately cancels this Amber alarm.")
    }
    static var mutatingReason: String {
        string("alarm.approval.mutating_reason", "This changes a system alarm on your iPhone and requires your approval.")
    }
    static var listReason: String {
        string("alarm.approval.list_reason", "This reads the alarms created by Amber on your iPhone and requires your approval.")
    }

    static var scheduleTool: String { string("alarm.tool.schedule", "Schedule system alarm (will sound)") }
    static var listTool: String { string("alarm.tool.list", "View Amber alarms") }
    static var cancelTool: String { string("alarm.tool.cancel", "Cancel system alarm") }

    static var titleField: String { string("alarm.field.title", "Title") }
    static var timeField: String { string("alarm.field.time", "Time") }
    static var typeField: String { string("alarm.field.type", "Type") }
    static var weekdaysField: String { string("alarm.field.weekdays", "Weekdays") }
    static var hourField: String { string("alarm.field.hour", "Hour") }
    static var minuteField: String { string("alarm.field.minute", "Minute") }
    static var durationField: String { string("alarm.field.duration_seconds", "Duration (seconds)") }
    static var identifierField: String { string("alarm.field.identifier", "Alarm ID") }
    static var noAdditionalParameters: String {
        string("alarm.field.no_additional_parameters", "No additional parameters")
    }

    static var denyButton: String { string("alarm.button.deny", "Deny") }
    static var approveButton: String { string("alarm.button.approve", "Approve") }
    static var cancelButton: String { string("alarm.button.cancel", "Cancel alarm") }
    static var openButton: String { string("alarm.button.open", "Open Amber") }
    static var stopButton: String { string("alarm.button.stop", "Stop") }

    static func accessibilityState(for mode: AlarmPresentationState.Mode) -> String {
        switch mode {
        case .countdown:
            countdown
        case .paused:
            paused
        case .alert:
            ringing
        @unknown default:
            defaultTitle
        }
    }

    private static func string(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(
            key,
            tableName: "AlarmKit",
            bundle: .main,
            value: fallback,
            comment: ""
        )
    }
}
#endif
