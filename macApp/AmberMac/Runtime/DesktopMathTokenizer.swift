import Foundation

enum DesktopMathSegment: Equatable {
    case text(String)
    case formula(String)
}

enum DesktopMathTokenizer {
    static func inline(_ source: String) -> [DesktopMathSegment] {
        let chars = Array(source)
        var result: [DesktopMathSegment] = [], text = "", index = 0
        while index < chars.count {
            if chars[index] == "`" {
                let start = index
                while index < chars.count, chars[index] == "`" { index += 1 }
                let count = index - start
                var end = index
                while end < chars.count {
                    if chars[end] == "`" {
                        let run = end
                        while end < chars.count, chars[end] == "`" { end += 1 }
                        if end - run == count { break }
                    } else { end += 1 }
                }
                text += String(chars[start..<end]); index = end; continue
            }
            let slashMath = chars[index] == "\\" && !escaped(chars, index) && index + 1 < chars.count && chars[index + 1] == "("
            let dollar = chars[index] == "$" && !escaped(chars, index) && (index == 0 || chars[index - 1] != "$")
                && index + 1 < chars.count && chars[index + 1] != "$" && !chars[index + 1].isWhitespace
            if slashMath || dollar {
                let start = index + (slashMath ? 2 : 1)
                var end = start
                while end < chars.count, chars[end] != "\n" {
                    let close = slashMath ? chars[end] == "\\" && !escaped(chars, end) && end + 1 < chars.count && chars[end + 1] == ")"
                        : chars[end] == "$" && !escaped(chars, end) && end > start && !chars[end - 1].isWhitespace
                            && (end + 1 == chars.count || !chars[end + 1].isNumber)
                    if close {
                        if !text.isEmpty { result.append(.text(text)); text = "" }
                        result.append(.formula(String(chars[start..<end])))
                        index = end + (slashMath ? 2 : 1)
                        break
                    }
                    end += 1
                }
                if index > end { continue }
            }
            text.append(chars[index]); index += 1
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    static func block(lines: [String], at index: Int) -> (source: String, end: Int)? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let open: String, close: String
        if line.hasPrefix("$$") { open = "$$"; close = "$$" }
        else if line.hasPrefix("\\[") { open = "\\["; close = "\\]" }
        else { return nil }
        let first = String(line.dropFirst(open.count))
        if first.hasSuffix(close) { return (String(first.dropLast(close.count)), index) }
        var content = [first]
        for next in lines.indices where next > index {
            let value = lines[next].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("```") || value.hasPrefix("~~~") { return nil }
            if value.hasSuffix(close) {
                content.append(String(value.dropLast(close.count)))
                return (content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), next)
            }
            content.append(lines[next])
        }
        return nil
    }

    private static func escaped(_ chars: [Character], _ index: Int) -> Bool {
        var count = 0, cursor = index
        while cursor > 0, chars[cursor - 1] == "\\" { count += 1; cursor -= 1 }
        return count % 2 == 1
    }
}
