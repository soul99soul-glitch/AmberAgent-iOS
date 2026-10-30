import SwiftUI
import UIKit
import Shared

/// Phone receipts distinguish a dispatched action from a verified business result.
/// Only counts and evidence availability belong in the capsule; UI text and parameters
/// remain in the explicitly expanded detail sheet.
struct ChatPhoneToolPresentation {
    let state: ChatToolStepState
    let statusTitle: String
    let titleSuffix: String?
    let summary: String?
    let notice: String?
    let reason: String?
    /// The action may have run but its result was lost; the user must check the phone.
    let isOutcomeUnknown: Bool

    init(toolName: String, executed: Bool, analysis: ChatToolOutputAnalysis) {
        guard executed else {
            isOutcomeUnknown = false
            state = .active
            statusTitle = Self.localized("进行中")
            titleSuffix = nil
            summary = nil
            notice = nil
            reason = nil
            return
        }
        let result = analysis.firstJSONObject ?? [:]
        // Parsed once per output snapshot by ChatToolOutputAnalysis.
        let prior = analysis.priorToolReceipt
        let receipt = analysis.priorToolReceiptResult ?? result
        let status = (result["status"] as? String)?.lowercased()
        let outcome = (result["outcome"] as? String)?.lowercased()
        let verification = result["verification"] as? [String: Any]
        let verificationStatus = verification?["status"] as? String
        let isUnknown = status == "unknown" || outcome == "unknown" || prior?["kind"] as? String == "unknown"
        isOutcomeUnknown = isUnknown
        let isHandback = status == "handback"
        let returnReceipt = result["return_to_amber"] as? [String: Any]
        let needsVerification = (toolName == "phone_stop" && returnReceipt != nil && returnReceipt?["verified"] as? Bool != true)
            || (toolName == "phone_return_to_amber" && outcome == "completed" && result["verified"] as? Bool != true)
            || verificationStatus == "unmet" || verificationStatus == "insufficient"
            || (["phone_act", "phone_system"].contains(toolName) && outcome == "completed" && result["fresh_observation_available"] as? Bool == false)

        if isUnknown {
            state = .failed
            statusTitle = Self.localized("结果未知，需核对")
            titleSuffix = Self.localized("待核对")
            notice = Self.localized("动作可能已经执行。请先核对手机实际结果，不要重放该动作或整个流程。")
        } else if isHandback {
            state = .cancelled
            statusTitle = Self.localized("已交回，待继续")
            titleSuffix = Self.localized("待继续")
            notice = Self.localized("本次自动步骤已结束；保留已有执行回执，根据最新界面继续，不能整体重放。")
        } else if needsVerification {
            state = .cancelled
            statusTitle = Self.localized("已执行，待核验")
            titleSuffix = Self.localized("待核验")
            notice = Self.localized("动作已有执行回执，验收条件尚未确认。重新观察核验，不能据此重放动作。")
        } else if analysis.failureReason != nil || (outcome == "not_sent" && status != "completed")
                    || result["cleanup_complete"] as? Bool == false {
            state = .failed
            statusTitle = Self.localized(outcome == "not_sent" ? "未执行" : "执行失败")
            titleSuffix = nil
            notice = nil
        } else {
            state = .done
            statusTitle = Self.localized(toolName == "phone_act" && verificationStatus != "satisfied" ? "已执行" : "已完成")
            titleSuffix = nil
            notice = nil
        }

        var facts: [String] = []
        if toolName == "phone_return_to_amber", result["verified"] as? Bool == true {
            facts.append(Self.localized("已确认 Amber 在前台"))
        }
        if toolName == "phone_clipboard", let characters = result["returned_chars"] as? Int {
            facts.append(Self.formatted("已读取 %ld 字符", characters))
        }
        if let steps = receipt["steps"] as? [Any] {
            let count = steps.filter { step in
                if let text = step as? String { return text.hasSuffix(": completed") }
                let object = step as? [String: Any]
                return ((object?["outcome"] ?? object?["status"]) as? String) == "completed"
            }.count
            facts.append(Self.formatted("已确认执行 %ld 步", count))
        } else if toolName == "phone_act", receipt["outcome"] as? String == "completed" {
            facts.append(Self.localized("已有动作执行回执"))
        } else if outcome == "not_sent" {
            facts.append(Self.localized("本次未发送手机动作"))
        }
        if let count = receipt["swipe_count"] as? Int { facts.append(Self.formatted("已派发 %ld 次滑动", count)) }
        if let items = result["items"] as? [Any] { facts.append(Self.formatted("已采集 %ld 项", items.count)) }
        if let count = result["screen_count"] as? Int { facts.append(Self.formatted("观察 %ld 屏", count)) }
        if result["coverage"] as? String == "observed_screens_only" { facts.append(Self.localized("仅覆盖已观察页面")) }
        // Only the header line matters; never split a whole observation tree.
        let hasTree = analysis.textParts.contains { text in
            guard text.hasPrefix("app=") else { return false }
            let header = text.firstIndex(of: "\n").map { text[..<$0] } ?? text[...]
            return header.contains(" observation=")
        }
        if hasTree || result["fresh_observation_available"] as? Bool == true {
            facts.append(Self.localized("已附新界面"))
        } else if result["fresh_observation_available"] as? Bool == false {
            facts.append(Self.localized("尚无新界面"))
        }
        for object in analysis.jsonObjects {
            if let ocr = object["screen_text"] as? [String: Any], let items = ocr["items"] as? [Any] {
                facts.append(Self.formatted("OCR 识别 %ld 项文字", items.count))
            }
        }
        if toolName == "phone_act", outcome == "completed", verification == nil {
            facts.append(Self.localized("业务结果尚未验收"))
        } else if verificationStatus == "satisfied" {
            facts.append(Self.localized("验收条件已满足"))
        }
        summary = facts.isEmpty ? nil : facts.joined(separator: "；")
        reason = [result["reason"], verification?["reason"], result["observation_error"], result["detail"], result["message"]]
            .compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { String($0.prefix(512)) }
    }

    private static func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }

    private static func formatted(_ key: String, _ count: Int) -> String {
        IOSAppLocalization.formatted(key, defaultValue: key, arguments: [count])
    }

    /// Memoized per output snapshot (and app language): step models are rebuilt by
    /// the timeline, the activity island and phone tool grouping for the same tool.
    /// `language` lets batch callers (phone-step grouping) resolve the app language
    /// once per pass instead of reading preferences per tool.
    static func cached(
        toolName: String,
        executed: Bool,
        analysis: ChatToolOutputAnalysis,
        language: String? = nil
    ) -> ChatPhoneToolPresentation {
        guard executed else {
            return ChatPhoneToolPresentation(toolName: toolName, executed: false, analysis: analysis)
        }
        let language = language ?? currentLanguageKey()
        return analysis.derivedValues.value(forKey: "phone|\(toolName)|\(language)") {
            ChatPhoneToolPresentation(toolName: toolName, executed: true, analysis: analysis)
        }
    }

    static func currentLanguageKey() -> String {
        IOSAppLanguagePreference.selected().resolvedLanguage(preferredLanguages: Locale.preferredLanguages).rawValue
    }
}

