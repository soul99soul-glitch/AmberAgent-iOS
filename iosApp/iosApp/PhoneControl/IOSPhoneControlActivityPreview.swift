#if DEBUG && targetEnvironment(simulator)
import ActivityKit
import UIKit

/// Explicit simulator fixture for the system-rendered widget, never device control.
enum IOSPhoneControlActivityPreview {
    static let argument = "-amber-phone-activity-preview"
    private static let runID = "amber-phone-activity-preview"
    // Only enables the widget's conversation-backed button layout; no conversation or phone owner is created.
    private static let conversationID = "6b9cd9fc-87b3-4f15-a978-9b81538833c0"

    @MainActor
    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return }
        let value = arguments[index + 1]
        for activity in Activity<AgentActivityAttributes>.activities where [runID, runID + "-secondary"].contains(activity.attributes.runId) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if value == "end" { return }
        let presentation: AgentActivityPresentation
        if value == "finalUnknown" {
            presentation = .failed().preservingUnknownPhoneOutcome(from: .phoneControl(.outcomeUnknown))
        } else if let phase = AgentPhoneControlActivityPhase(rawValue: value) {
            presentation = .phoneControl(phase)
        } else { return }
        do {
            for _ in 0..<50 {
                if UIApplication.shared.applicationState == .active { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard UIApplication.shared.applicationState == .active else { return }
            let attributes = AgentActivityAttributes(
                runId: runID, conversationId: conversationID, startedAt: Date(), conversationTitle: "手机控制状态预览"
            )
            let state = AgentActivityAttributes.ContentState(
                presentation: presentation, updatedAt: Date(), languageCode: "zh-Hans"
            )
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            if arguments.contains("-amber-phone-activity-preview-secondary") {
                let secondary = AgentActivityAttributes(
                    runId: runID + "-secondary", conversationId: conversationID, startedAt: Date(), conversationTitle: "第二张预览"
                )
                _ = try Activity.request(attributes: secondary, content: ActivityContent(state: state, staleDate: nil))
            }
            print("PHONE_ACTIVITY_PREVIEW \(value)")
        } catch {
            print("PHONE_ACTIVITY_PREVIEW failed: \(error.localizedDescription)")
        }
    }
}
#endif
