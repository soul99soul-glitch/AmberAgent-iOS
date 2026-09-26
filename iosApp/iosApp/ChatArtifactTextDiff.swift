import Foundation

enum ChatArtifactTextDiff {
    enum Kind: Equatable {
        case unchanged
        case removed
        case added
    }

    struct Line: Equatable {
        let text: String
        let kind: Kind
    }

    static func lines(previous: String, current: String, limit: Int = 80) -> [Line] {
        let previousLines = lines(previous)
        let currentLines = lines(current)
        guard previousLines != currentLines else {
            return [Line(text: "两版内容相同", kind: .unchanged)]
        }

        let difference = currentLines.difference(from: previousLines)
        let removedOffsets = Set(difference.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let addedOffsets = Set(difference.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var output: [Line] = []
        var previousIndex = 0
        var currentIndex = 0
        var removedCount = 0
        var addedCount = 0
        var omittedCount = 0

        while previousIndex < previousLines.count || currentIndex < currentLines.count {
            if previousIndex < previousLines.count, removedOffsets.contains(previousIndex) {
                if removedCount < limit {
                    output.append(Line(text: "− \(previousLines[previousIndex])", kind: .removed))
                } else {
                    omittedCount += 1
                }
                removedCount += 1
                previousIndex += 1
            } else if currentIndex < currentLines.count, addedOffsets.contains(currentIndex) {
                if addedCount < limit {
                    output.append(Line(text: "+ \(currentLines[currentIndex])", kind: .added))
                } else {
                    omittedCount += 1
                }
                addedCount += 1
                currentIndex += 1
            } else {
                previousIndex += 1
                currentIndex += 1
            }
        }
        if omittedCount > 0 {
            output.append(Line(text: "…另有 \(omittedCount) 行差异", kind: .unchanged))
        }
        return output
    }

    private static func lines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: "\n")
    }
}
