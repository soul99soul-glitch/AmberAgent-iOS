import Foundation

struct JSONDuplicateKeyValidator {
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        var validator = JSONDuplicateKeyValidator(bytes: Array(data))
        try validator.parseValue(path: "$")
        validator.skipWhitespace()
        guard validator.index == validator.bytes.count else {
            throw validator.malformed()
        }
    }

    private mutating func parseValue(path: String) throws {
        skipWhitespace()
        guard let byte = current else { throw malformed() }
        switch byte {
        case 0x7B: // {
            try parseObject(path: path)
        case 0x5B: // [
            try parseArray(path: path)
        case 0x22: // "
            _ = try parseString()
        default:
            try parsePrimitive()
        }
    }

    private mutating func parseObject(path: String) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }

        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard current == 0x22 else { throw malformed() }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw NovelStructuredOutputFailure(
                    category: .duplicateKey,
                    path: path + "." + key,
                    message: "The model output repeats object key '\(key)'."
                )
            }
            skipWhitespace()
            guard consume(0x3A) else { throw malformed() }
            try parseValue(path: path + "." + key)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw malformed() }
        }
    }

    private mutating func parseArray(path: String) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        var elementIndex = 0
        while true {
            try parseValue(path: "\(path)[\(elementIndex)]")
            elementIndex += 1
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw malformed() }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw malformed() }
        var escaped = false
        while let byte = current {
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let slice = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: slice) else {
                    throw malformed()
                }
                return value
            }
        }
        throw malformed()
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while let byte = current,
              byte != 0x2C, byte != 0x5D, byte != 0x7D,
              !Self.isWhitespace(byte) {
            index += 1
        }
        guard index > start else { throw malformed() }
    }

    private mutating func skipWhitespace() {
        while let byte = current, Self.isWhitespace(byte) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func malformed() -> NovelStructuredOutputFailure {
        NovelStructuredOutputFailure(
            category: .malformedJSON,
            path: "$",
            message: "The model returned malformed JSON."
        )
    }
}
