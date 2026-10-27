import Foundation
let total = 8 * 1024 * 1024
let chunk = Data(repeating: 97, count: 8192)
@inline(never) func scan(_ incremental: Bool) -> Int {
    var buffer = Data()
    var scanned = 0
    for _ in 0..<(total / chunk.count) {
        buffer.append(chunk)
        let start = incremental ? buffer.startIndex + scanned : buffer.startIndex
        if buffer[start...].firstIndex(of: 10) != nil { return -1 }
        scanned = buffer.count
    }
    return buffer.count
}
for incremental in [false, true] {
    let start = ContinuousClock.now
    let result = scan(incremental)
    print(incremental ? "incremental" : "existing", result, ContinuousClock.now - start)
}
