import Foundation

/// 一次矛盾修复要改的章。目标永远是**较后**的那一章：先文当事实，后文去对齐。
struct NovelContinuityRepairJob: Equatable, Sendable {
    let chapterID: NovelChapterID
    let chapterOrdinal: Int
    let chapterTitle: String
    let issues: [NovelContinuityIssue]
}

/// 一键修复的结果。**不写进项目文档**：报告本身仍是诊断，真正落盘的是各章
/// `saveManualEdit` 新版本。界面拿它标出已改掉的条目。
struct NovelContinuityRepairReport: Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let repairedIssueIDs: [String]
    let skippedIssueIDs: [String]
    let repairedChapterCount: Int
    let failedChapterCount: Int
}

enum NovelContinuityRepairPlanner {
    /// 按「较后章」分组。同一章的多条问题合并成一次模型调用，避免一章被改写多次。
    static func jobs(
        from issues: [NovelContinuityIssue],
        issueIDs: Set<String>? = nil
    ) -> [NovelContinuityRepairJob] {
        let selected = issues.filter { issue in
            guard let issueIDs else { return true }
            return issueIDs.contains(issue.id)
        }
        var grouped: [NovelChapterID: NovelContinuityRepairJob] = [:]
        for issue in selected {
            guard let target = targetReference(in: issue) else { continue }
            if var existing = grouped[target.chapterID] {
                existing = NovelContinuityRepairJob(
                    chapterID: existing.chapterID,
                    chapterOrdinal: existing.chapterOrdinal,
                    chapterTitle: existing.chapterTitle,
                    issues: existing.issues + [issue]
                )
                grouped[target.chapterID] = existing
            } else {
                grouped[target.chapterID] = NovelContinuityRepairJob(
                    chapterID: target.chapterID,
                    chapterOrdinal: target.chapterOrdinal,
                    chapterTitle: target.chapterTitle,
                    issues: [issue]
                )
            }
        }
        return grouped.values.sorted { $0.chapterOrdinal < $1.chapterOrdinal }
    }

    /// 矛盾成对时，较后的落点才是要改的一侧。先文保持不动。
    static func targetReference(in issue: NovelContinuityIssue) -> NovelContinuityReference? {
        issue.references.max(by: { lhs, rhs in
            if lhs.chapterOrdinal != rhs.chapterOrdinal {
                return lhs.chapterOrdinal < rhs.chapterOrdinal
            }
            return lhs.chapterID.description < rhs.chapterID.description
        }).flatMap { latest in
            issue.references.contains { $0.chapterOrdinal < latest.chapterOrdinal }
                ? latest
                : nil
        }
    }

    static func canonicalReferences(in issue: NovelContinuityIssue) -> [NovelContinuityReference] {
        guard let target = targetReference(in: issue) else { return [] }
        return issue.references.filter { $0.chapterOrdinal < target.chapterOrdinal }
    }
}

enum NovelContinuityRepairPatchApplier {
    struct Applied: Equatable, Sendable {
        let content: String
        let appliedIssueIDs: [String]
        let droppedCount: Int
    }

    /// 只替换**唯一**出现的原文。出现 0 次或 2 次以上、互相重叠、或新旧相同的补丁整条丢弃。
    /// 从后往前替换，避免前面的改写打乱后面的落点。
    static func apply(
        _ patches: [NovelContinuityRepairPatchV1],
        to content: String,
        allowedIssueIDs: Set<String>
    ) -> Applied {
        struct LocatedPatch {
            let issueID: String
            let range: Range<String.Index>
            let newText: String
        }

        var located: [LocatedPatch] = []
        var dropped = 0
        var claimedIssueIDs: Set<String> = []
        for patch in patches {
            let issueID = patch.issueId.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldText = patch.oldText
            let newText = patch.newText
            guard allowedIssueIDs.contains(issueID),
                  claimedIssueIDs.insert(issueID).inserted,
                  !oldText.isEmpty,
                  !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  oldText != newText,
                  let range = uniqueRange(of: oldText, in: content) else {
                dropped += 1
                continue
            }
            located.append(LocatedPatch(issueID: issueID, range: range, newText: newText))
        }

        located.sort { $0.range.lowerBound < $1.range.lowerBound }
        var kept: [LocatedPatch] = []
        var lastEnd: String.Index?
        for patch in located {
            if let lastEnd, patch.range.lowerBound < lastEnd {
                dropped += 1
                continue
            }
            kept.append(patch)
            lastEnd = patch.range.upperBound
        }

        var next = content
        for patch in kept.reversed() {
            next.replaceSubrange(patch.range, with: patch.newText)
        }
        return Applied(
            content: next,
            appliedIssueIDs: kept.map(\.issueID),
            droppedCount: dropped
        )
    }

    static func uniqueRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        guard !needle.isEmpty, let first = haystack.range(of: needle) else { return nil }
        if haystack.range(of: needle, range: first.upperBound..<haystack.endIndex) != nil {
            return nil
        }
        return first
    }
}

enum NovelContinuityRepairPrompt {
    static func userMessage(for job: NovelContinuityRepairJob, chapterContent: String) -> String {
        var lines: [String] = [
            "TARGET CHAPTER",
            "# Chapter \(job.chapterOrdinal): \(job.chapterTitle)",
            chapterContent,
            "",
            "ISSUES TO REPAIR",
            "Keep earlier-chapter facts. Rewrite only this chapter. Copy oldText verbatim from TARGET CHAPTER.",
        ]
        for issue in job.issues {
            lines.append("- id:\(issue.id) [\(issue.category.rawValue)] \(issue.summary)")
            for reference in NovelContinuityRepairPlanner.canonicalReferences(in: issue) {
                lines.append(
                    "  Canonical Chapter \(reference.chapterOrdinal) \(reference.chapterTitle): \(reference.evidence)"
                )
            }
            if let target = NovelContinuityRepairPlanner.targetReference(in: issue) {
                lines.append(
                    "  Conflict in this chapter: \(target.evidence)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}
