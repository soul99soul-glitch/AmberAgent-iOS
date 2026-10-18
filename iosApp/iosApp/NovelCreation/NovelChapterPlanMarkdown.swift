import Foundation

enum NovelChapterPlanMarkdown {
    static func looksLike(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            Section(heading: line.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    static func parse(_ raw: String) throws -> NovelChapterPlanProposalV1 {
        var buckets: [Section: [String]] = [:]
        var section: Section?
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let next = Section(heading: trimmed) {
                section = next
                continue
            }
            guard let section else { continue }
            buckets[section, default: []].append(String(line))
        }
        let goal = prose(buckets[.goal] ?? [])
        let mustHappen = listItems(buckets[.mustHappen] ?? [])
        guard !goal.isEmpty else {
            throw NovelStructuredOutputFailure(
                category: .invalidValue,
                path: "$.goalAndConflict",
                message: "本章计划缺少「目标」。"
            )
        }
        guard !mustHappen.isEmpty else {
            throw NovelStructuredOutputFailure(
                category: .invalidValue,
                path: "$.mustHappen",
                message: "本章计划缺少「必发生」。"
            )
        }
        return NovelChapterPlanProposalV1(
            outlinePlacement: prose(buckets[.title] ?? []),
            goalAndConflict: goal,
            mustHappen: mustHappen,
            mustNotHappen: listItems(buckets[.mustNotHappen] ?? []),
            endingHook: prose(buckets[.endingHook] ?? []),
            visibleFacts: listItems(buckets[.visibleFacts] ?? [])
        )
    }

    private enum Section: Hashable {
        case title
        case goal
        case mustHappen
        case mustNotHappen
        case endingHook
        case visibleFacts

        init?(heading: String) {
            let stripped = heading.replacingOccurrences(
                of: #"^#{1,3}\s*"#,
                with: "",
                options: .regularExpression
            )
            switch stripped {
            case "章名", "与总纲的位置":
                self = .title
            case "目标", "目标与冲突":
                self = .goal
            case "必发生", "必发生（每行一条）":
                self = .mustHappen
            case "禁止发生", "禁止发生（每行一条）":
                self = .mustNotHappen
            case "章末钩子":
                self = .endingHook
            case "可见要点", "POV 可见要点", "POV 可见要点（每行一条）":
                self = .visibleFacts
            default:
                return nil
            }
        }
    }

    private static func prose(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func listItems(_ lines: [String]) -> [String] {
        NovelChapterPlanRecord.normalizedLines(lines.map { raw in
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2))
            } else if let bullet = line.range(
                of: #"^\d+[.)、]\s*"#,
                options: .regularExpression
            ) {
                line = String(line[bullet.upperBound...])
            }
            return line
        })
    }
}
