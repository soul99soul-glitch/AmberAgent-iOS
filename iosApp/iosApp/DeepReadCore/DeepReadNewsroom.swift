import Foundation

/// Maps the runtime's real progress labels onto a newsroom metaphor.
enum DeepReadNewsroomStage: Int, CaseIterable {
    case interview, collate, write, press

    static func from(label: String?) -> Self {
        guard let label else { return .interview }
        if label.contains("抓取") { return .collate }
        if label.contains("保存") { return .press }
        // Stage callbacks fire after a chapter is written, so the last chapter's label means the draft is done.
        if label.hasSuffix("扩展阅读") { return .press }
        if label.hasPrefix("正在生成") { return .write }
        return .interview
    }

    var title: String {
        switch self {
        case .interview: "采访"
        case .collate: "整理"
        case .write: "撰稿"
        case .press: "付印"
        }
    }

    var symbol: String {
        switch self {
        case .interview: "magnifyingglass"
        case .collate: "doc.on.doc"
        case .write: "pencil.and.scribble"
        case .press: "seal"
        }
    }

    var headline: String {
        switch self {
        case .interview: "记者正在多方采访"
        case .collate: "编辑正在整理素材"
        case .write: "主笔正在撰写文章"
        case .press: "即将付印"
        }
    }
}

/// Date-driven flourishes. Pure so the calendar rules stay testable.
enum DeepReadMoment {
    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 5
    }

    static func festival(on date: Date, calendar: Calendar = .current) -> (name: String, symbol: String)? {
        // Solar holidays are Gregorian dates even when the user's calendar is not.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let day = gregorian.dateComponents([.month, .day], from: date)
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        let lunarDay = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
        if lunarDay.isLeapMonth != true {
            switch (lunarDay.month ?? 0, lunarDay.day ?? 0) {
            case (1, 1...7): return ("新春 · 开卷有益", "fireworks")
            case (1, 15): return ("元宵 · 灯下读", "lamp.table")
            case (8, 15): return ("中秋 · 月下读", "moon.stars")
            default: break
            }
        }
        switch (day.month ?? 0, day.day ?? 0) {
        case (1, 1): return ("元旦 · 新年第一读", "sparkles")
        case (4, 23): return ("世界读书日", "book.closed")
        case (10, 1...7): return ("国庆 · 慢慢读", "flag")
        case (12, 24), (12, 25): return ("圣诞 · 围炉夜读", "snowflake")
        default: return nil
        }
    }

    static func milestone(completedCount: Int) -> String? {
        switch completedCount {
        case 1: "首篇"
        case 10: "十篇"
        case 100: "百篇"
        default: nil
        }
    }

    /// Seal for a run that just finished while the reader watched. A retry that kept the old
    /// article after cancel/failure is not a fresh print; only a first draft counts toward milestones.
    static func pressSeal(finishedWithError: Bool, wasFirstDraft: Bool, completedCount: Int) -> (inscription: String, caption: String)? {
        guard !finishedWithError else { return nil }
        if wasFirstDraft, let milestone = milestone(completedCount: completedCount) {
            return (milestone, "你的第 \(completedCount) 篇深度阅读")
        }
        return ("付印", "文章已排版完成")
    }
}
