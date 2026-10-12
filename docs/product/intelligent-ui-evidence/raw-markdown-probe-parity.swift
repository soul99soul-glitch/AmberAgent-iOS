import Foundation
func check(_ text: String, filtered: Bool) -> Bool {
    let native = text as NSString
    if filtered {
        if native.range(of: "**", options: .literal).location != NSNotFound && text.contains("**") { return true }
        if native.range(of: "## ", options: .literal).location != NSNotFound && text.contains("## ") { return true }
        if native.range(of: " | ", options: .literal).location != NSNotFound && text.contains(" | ") && text.contains("|") { return true }
    } else {
        if text.contains("**") || text.contains("## ") { return true }
        if text.contains(" | ") && text.contains("|") { return true }
    }
    if !filtered || native.range(of: "- ", options: .literal).location != NSNotFound || native.range(of: "* ", options: .literal).location != NSNotFound {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
        }
    }
    return false
}
let samples: [(String, Bool)] = [
    ("", false), ("plain prose", false), ("a - b", false), ("a * b", false),
    ("**bold**", true), ("## title", true), ("a | b | c", true),
    ("- item", true), ("* item", true), ("line\n  - item", true),
    ("line\n\t* item", true), ("line\r\n- item", false),
    ("\u{A0}- item", true), ("\u{2003}* item", true),
    ("\u{1F600} - item", false), ("*\u{301} item", false)
]
for (text, expected) in samples {
    precondition(check(text, filtered: false) == expected)
    precondition(check(text, filtered: true) == expected)
}
let markers = ["**", "## ", " | ", "- ", "* "]
let decorations = ["", "\u{301}", "\u{FE0F}", "\u{200B}", "\u{1F600}", "\u{D}"]
var parityCases = 0
for marker in markers {
    for decoration in decorations {
        for i in 0...marker.count {
            let split = marker.index(marker.startIndex, offsetBy: i)
            let text = "\u{4E2D}" + marker[..<split] + decoration + marker[split...] + "\u{6587}"
            precondition(check(text, filtered: false) == check(text, filtered: true))
            parityCases += 1
        }
    }
}
print("Additional Unicode adjacency cases PASS:", parityCases)
let backing = NSMutableString(string: String(repeating: "\u{8FDE}\u{7EED}\u{6B63}\u{6587}\u{5185}\u{5BB9}", count: 4400))
let foreign = backing as String
let rounds = 100
var result = false
func measure(_ filtered: Bool) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<rounds { result = check(foreign, filtered: filtered) }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(rounds)
}
print("16 semantic cases PASS; all original marker checks retained")
print(String(format: "Foreign NSString, %d UTF16 units, %d rounds: old %.3fms/check, filtered %.3fms/check; result=%@", backing.length, rounds, measure(false), measure(true), String(result)))
