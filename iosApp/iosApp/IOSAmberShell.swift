import Foundation

struct IOSAmberShellCommandResult: Equatable {
    let exitCode: Int?
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let termination: IOSAmberShellTermination?
}

enum IOSAmberShellTermination: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "AmberShell command was cancelled."
        case .timedOut:
            "AmberShell command timed out."
        }
    }
}

@MainActor
enum IOSAmberShellEngine {
    nonisolated private static let coreCommands: [String] = [
        "pwd", "ls", "echo", "printf", "cat", "mkdir", "touch", "cp", "mv", "rm",
        "head", "tail", "wc", "grep", "sort", "uniq", "cut", "tr", "basename",
        "dirname", "env", "date", "uname",
    ]

    #if ENABLE_AMBERSHELL_PYTHON
    nonisolated static let supportedCommands = coreCommands + ["python"]
    #else
    nonisolated static let supportedCommands = coreCommands
    #endif

    private static let maxCommandCharacters = 4_096
    private static let maxInputBytes = IOSAmberShellInputContract.maxStdinBytes
    private static let maxOutputBytes = 128 * 1024

    static func execute(
        command: String,
        stdin: String? = nil,
        workspaceStore: IOSWorkspaceStore,
        control: IOSAmberShellExecutionControl? = nil
    ) async -> IOSAmberShellCommandResult {
        do {
            try control?.checkpoint()
            guard command.count <= maxCommandCharacters else {
                throw IOSAmberShellCommandError.usage(
                    "AmberShell 单条命令不能超过 \(maxCommandCharacters) 个字符。"
                )
            }
            if let stdin, stdin.utf8.count > maxInputBytes {
                throw IOSAmberShellCommandError.usage("AmberShell stdin 不能超过 65536 UTF-8 bytes。")
            }

            let program = try IOSAmberShellParser.parse(command)
            try control?.checkpoint()
            if let stdoutPath = program.stdoutRedirect,
               let stderrPath = program.stderrRedirect,
               try workspaceStore.amberShellPathIdentity(stdoutPath)
                    == workspaceStore.amberShellPathIdentity(stderrPath) {
                throw IOSAmberShellCommandError.syntax("stdout 与 stderr 不能重定向到同一个文件。")
            }
            if let path = program.stdoutRedirect {
                try workspaceStore.amberShellValidateWriteTarget(path: path)
            }
            if let path = program.stderrRedirect {
                try workspaceStore.amberShellValidateWriteTarget(path: path)
            }

            var stageInput = stdin ?? ""
            if let path = program.stdinRedirect {
                try control?.checkpoint()
                guard stdin == nil else {
                    throw IOSAmberShellCommandError.syntax("显式 stdin 与 < 输入重定向不能同时使用。")
                }
                stageInput = try workspaceStore.amberShellReadText(path: path, maxBytes: maxInputBytes)
                try control?.checkpoint()
            }

            var stdout = ""
            var stderr = ""
            var exitCode = 0
            for (index, stage) in program.stages.enumerated() {
                try control?.checkpoint()
                let result: IOSAmberShellStageResult
                do {
                    result = try await executeStage(
                        arguments: stage.arguments,
                        stdin: stageInput,
                        workspaceStore: workspaceStore,
                        control: control
                    )
                } catch let termination as IOSAmberShellTermination {
                    throw termination
                } catch let error as IOSAmberShellCommandError {
                    result = IOSAmberShellStageResult(
                        exitCode: error.exitCode,
                        stdout: "",
                        stderr: error.localizedDescription + "\n"
                    )
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    result = IOSAmberShellStageResult(exitCode: 74, stdout: "", stderr: message + "\n")
                }
                try control?.checkpoint()

                stdout = result.stdout
                stderr += result.stderr
                exitCode = result.exitCode
                guard exitCode == 0 else { break }

                if index < program.stages.count - 1 {
                    guard stdout.utf8.count <= maxInputBytes else {
                        throw IOSAmberShellCommandError.usage(
                            "AmberShell pipeline 的段间输出不能超过 65536 UTF-8 bytes。"
                        )
                    }
                    stageInput = stdout
                }
            }

            if let path = program.stdoutRedirect {
                try control?.checkpoint()
                try await workspaceStore.amberShellWriteText(path: path, text: stdout)
                try control?.checkpoint()
                stdout = ""
            }
            if let path = program.stderrRedirect {
                try control?.checkpoint()
                try await workspaceStore.amberShellWriteText(path: path, text: stderr)
                try control?.checkpoint()
                stderr = ""
            }
            try control?.checkpoint()
            return boundedResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        } catch let termination as IOSAmberShellTermination {
            return boundedResult(
                exitCode: nil,
                stdout: "",
                stderr: (termination.errorDescription ?? "AmberShell execution stopped.") + "\n",
                termination: termination
            )
        } catch let error as IOSAmberShellCommandError {
            return boundedResult(
                exitCode: error.exitCode,
                stdout: "",
                stderr: error.localizedDescription + "\n"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return boundedResult(exitCode: 74, stdout: "", stderr: message + "\n")
        }
    }

    private static func executeStage(
        arguments: [String],
        stdin: String,
        workspaceStore: IOSWorkspaceStore,
        control: IOSAmberShellExecutionControl?
    ) async throws -> IOSAmberShellStageResult {
        try control?.checkpoint()
        guard let name = arguments.first else {
            throw IOSAmberShellCommandError.usage("需要提供 AmberShell 命令。")
        }
        let operands = Array(arguments.dropFirst())

        switch name {
        case "pwd":
            try requireOperandCount(operands, command: name, allowed: 0...0)
            return success("/workspace\n")

        case "ls":
            try requireOperandCount(operands, command: name, allowed: 0...1)
            let entries = try workspaceStore.amberShellList(path: operands.first ?? "/workspace")
            var output = ""
            for entry in entries {
                try control?.checkpoint()
                try appendWithinOutputLimit(entry + "\n", to: &output)
            }
            return success(output)

        case "echo":
            return success(operands.joined(separator: " ") + "\n")

        case "printf":
            guard let format = operands.first else {
                throw IOSAmberShellCommandError.usage("用法：printf <格式> [参数…]")
            }
            return success(try renderPrintf(format: format, arguments: Array(operands.dropFirst())))

        case "cat":
            if operands.isEmpty { return success(stdin) }
            guard !operands.contains(where: { $0.hasPrefix("-") }) else {
                throw IOSAmberShellCommandError.usage("cat 当前不支持选项。")
            }
            var text = ""
            for path in operands {
                try control?.checkpoint()
                let part = try workspaceStore.amberShellReadText(path: path, maxBytes: maxOutputBytes)
                try appendWithinOutputLimit(part, to: &text)
            }
            return success(text)

        case "mkdir":
            try requireOperandCount(operands, command: name, allowed: 1...1)
            try workspaceStore.amberShellCreateDirectory(path: operands[0])
            return success("")

        case "touch":
            try requireOperandCount(operands, command: name, allowed: 1...1)
            try await workspaceStore.amberShellTouch(path: operands[0])
            return success("")

        case "cp":
            try requireOperandCount(operands, command: name, allowed: 2...2)
            try await workspaceStore.amberShellCopy(from: operands[0], to: operands[1])
            return success("")

        case "mv":
            try requireOperandCount(operands, command: name, allowed: 2...2)
            try await workspaceStore.amberShellMove(from: operands[0], to: operands[1])
            return success("")

        case "rm":
            try requireOperandCount(operands, command: name, allowed: 1...1)
            try workspaceStore.amberShellRemove(path: operands[0])
            return success("")

        case "head", "tail":
            let parsed = try lineSelectionArguments(operands, command: name)
            let text = try inputText(
                path: parsed.path,
                stdin: stdin,
                workspaceStore: workspaceStore
            )
            return success(selectedLines(text, count: parsed.count, fromEnd: name == "tail"))

        case "wc":
            let parsed = try wcArguments(operands)
            let text = try inputText(path: parsed.path, stdin: stdin, workspaceStore: workspaceStore)
            let lineCount = text.utf8.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            let byteCount = text.utf8.count
            let label = parsed.path.map { " \($0)" } ?? ""
            switch parsed.option {
            case "-l": return success("\(lineCount)\(label)\n")
            case "-w": return success("\(wordCount)\(label)\n")
            case "-c": return success("\(byteCount)\(label)\n")
            default: return success("\(lineCount) \(wordCount) \(byteCount)\(label)\n")
            }

        case "grep":
            let parsed = try grepArguments(operands)
            let text = try inputText(path: parsed.path, stdin: stdin, workspaceStore: workspaceStore)
            let pattern = parsed.caseInsensitive ? parsed.pattern.lowercased() : parsed.pattern
            let matches = logicalLines(text).filter { line in
                let candidate = parsed.caseInsensitive ? line.lowercased() : line
                return candidate.contains(pattern)
            }
            return IOSAmberShellStageResult(
                exitCode: matches.isEmpty ? 1 : 0,
                stdout: matches.isEmpty ? "" : matches.joined(separator: "\n") + "\n",
                stderr: ""
            )

        case "sort":
            let path = try optionalFileOperand(operands, command: name)
            let text = try inputText(path: path, stdin: stdin, workspaceStore: workspaceStore)
            let lines = logicalLines(text).sorted()
            return success(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")

        case "uniq":
            let parsed = try uniqArguments(operands)
            let text = try inputText(path: parsed.path, stdin: stdin, workspaceStore: workspaceStore)
            let lines = logicalLines(text)
            var groups: [(String, Int)] = []
            for line in lines {
                if groups.last?.0 == line {
                    groups[groups.count - 1].1 += 1
                } else {
                    groups.append((line, 1))
                }
            }
            let rendered = groups.map { line, count in
                parsed.counts ? "\(count) \(line)" : line
            }
            return success(rendered.isEmpty ? "" : rendered.joined(separator: "\n") + "\n")

        case "cut":
            let parsed = try cutArguments(operands)
            let text = try inputText(path: parsed.path, stdin: stdin, workspaceStore: workspaceStore)
            let output = logicalLines(text).map { line -> String in
                let fields = line.split(
                    separator: parsed.delimiter,
                    omittingEmptySubsequences: false
                )
                let index = parsed.field - 1
                return fields.indices.contains(index) ? String(fields[index]) : ""
            }
            return success(output.isEmpty ? "" : output.joined(separator: "\n") + "\n")

        case "tr":
            try requireOperandCount(operands, command: name, allowed: 2...2)
            let source = Array(operands[0])
            let destination = Array(operands[1])
            guard !source.isEmpty, source.count == destination.count else {
                throw IOSAmberShellCommandError.usage("tr 的 from/to 必须包含相同数量的字符。")
            }
            var mapping: [Character: Character] = [:]
            for (input, output) in zip(source, destination) {
                mapping[input] = output
            }
            return success(String(stdin.map { mapping[$0] ?? $0 }))

        case "basename":
            try requireOperandCount(operands, command: name, allowed: 1...1, rejectsOptions: false)
            return success(posixBasename(operands[0]) + "\n")

        case "dirname":
            try requireOperandCount(operands, command: name, allowed: 1...1, rejectsOptions: false)
            return success(posixDirname(operands[0]) + "\n")

        case "env":
            try requireOperandCount(operands, command: name, allowed: 0...0)
            return success("HOME=/workspace\nLANG=en_US.UTF-8\nPWD=/workspace\n")

        case "date":
            try requireOperandCount(operands, command: name, allowed: 0...0)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return success(formatter.string(from: Date()) + "\n")

        case "uname":
            guard operands.count <= 1,
                  operands.first.map({ ["-s", "-m", "-a"].contains($0) }) ?? true else {
                throw IOSAmberShellCommandError.usage("用法：uname [-s|-m|-a]")
            }
            switch operands.first {
            case "-m": return success("arm64\n")
            case "-a": return success("Darwin AmberShell arm64\n")
            default: return success("Darwin\n")
            }

        case "python":
            #if ENABLE_AMBERSHELL_PYTHON
            guard operands.count == 2, operands[0] == "-c", !operands[1].isEmpty else {
                throw IOSAmberShellCommandError.usage("用法：python -c <代码>")
            }
            let result = try await AmberShellPythonRuntime.shared.execute(
                source: operands[1],
                stdin: stdin,
                control: control
            )
            try control?.checkpoint()
            return IOSAmberShellStageResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
            #else
            throw IOSAmberShellCommandError.unsupported(name)
            #endif

        default:
            throw IOSAmberShellCommandError.unsupported(name)
        }
    }

    private static func success(_ stdout: String) -> IOSAmberShellStageResult {
        IOSAmberShellStageResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private static func appendWithinOutputLimit(_ value: String, to output: inout String) throws {
        guard output.utf8.count + value.utf8.count <= maxOutputBytes else {
            throw IOSAmberShellCommandError.usage("AmberShell 聚合输出不能超过 128 KiB。")
        }
        output += value
    }

    private static func requireOperandCount(
        _ operands: [String],
        command: String,
        allowed: ClosedRange<Int>,
        rejectsOptions: Bool = true
    ) throws {
        guard allowed.contains(operands.count) else {
            throw IOSAmberShellCommandError.usage("\(command) 的参数数量不正确。")
        }
        if rejectsOptions, operands.contains(where: { $0.hasPrefix("-") }) {
            throw IOSAmberShellCommandError.usage("\(command) 当前不支持选项。")
        }
    }

    private static func inputText(
        path: String?,
        stdin: String,
        workspaceStore: IOSWorkspaceStore
    ) throws -> String {
        guard let path else { return stdin }
        return try workspaceStore.amberShellReadText(path: path, maxBytes: maxOutputBytes)
    }

    private static func optionalFileOperand(_ operands: [String], command: String) throws -> String? {
        guard operands.count <= 1, !operands.contains(where: { $0.hasPrefix("-") }) else {
            throw IOSAmberShellCommandError.usage("用法：\(command) [文件]")
        }
        return operands.first
    }

    private static func lineSelectionArguments(
        _ operands: [String],
        command: String
    ) throws -> (count: Int, path: String?) {
        if operands.isEmpty { return (10, nil) }
        if operands.count == 1, !operands[0].hasPrefix("-") { return (10, operands[0]) }
        guard operands.count == 2 || operands.count == 3,
              operands[0] == "-n",
              let count = Int(operands[1]),
              (0...10_000).contains(count) else {
            throw IOSAmberShellCommandError.usage("用法：\(command) [-n 行数] [文件]")
        }
        return (count, operands.count == 3 ? operands[2] : nil)
    }

    private static func wcArguments(_ operands: [String]) throws -> (option: String?, path: String?) {
        if operands.isEmpty { return (nil, nil) }
        if operands.count == 1 {
            if operands[0].hasPrefix("-") {
                guard ["-l", "-w", "-c"].contains(operands[0]) else {
                    return try invalidWC()
                }
                return (operands[0], nil)
            }
            return (nil, operands[0])
        }
        guard operands.count == 2, ["-l", "-w", "-c"].contains(operands[0]) else {
            return try invalidWC()
        }
        return (operands[0], operands[1])
    }

    private static func invalidWC() throws -> (option: String?, path: String?) {
        throw IOSAmberShellCommandError.usage("用法：wc [-l|-w|-c] [文件]")
    }

    private static func grepArguments(
        _ operands: [String]
    ) throws -> (caseInsensitive: Bool, pattern: String, path: String?) {
        var values = operands
        let caseInsensitive = values.first == "-i"
        if caseInsensitive { values.removeFirst() }
        guard values.count == 1 || values.count == 2,
              !values[0].isEmpty,
              !values[0].hasPrefix("-") else {
            throw IOSAmberShellCommandError.usage("用法：grep [-i] <literal> [文件]")
        }
        return (caseInsensitive, values[0], values.count == 2 ? values[1] : nil)
    }

    private static func uniqArguments(_ operands: [String]) throws -> (counts: Bool, path: String?) {
        if operands.isEmpty { return (false, nil) }
        if operands.count == 1 {
            if operands[0] == "-c" { return (true, nil) }
            guard !operands[0].hasPrefix("-") else {
                throw IOSAmberShellCommandError.usage("用法：uniq [-c] [文件]")
            }
            return (false, operands[0])
        }
        guard operands.count == 2, operands[0] == "-c" else {
            throw IOSAmberShellCommandError.usage("用法：uniq [-c] [文件]")
        }
        return (true, operands[1])
    }

    private static func cutArguments(
        _ operands: [String]
    ) throws -> (delimiter: Character, field: Int, path: String?) {
        guard operands.count == 4 || operands.count == 5,
              operands[0] == "-d",
              operands[1].count == 1,
              operands[2] == "-f",
              let field = Int(operands[3]),
              field > 0,
              let delimiter = operands[1].first else {
            throw IOSAmberShellCommandError.usage("用法：cut -d <单字符> -f <正整数> [文件]")
        }
        return (delimiter, field, operands.count == 5 ? operands[4] : nil)
    }

    private static func selectedLines(_ text: String, count: Int, fromEnd: Bool) -> String {
        guard count > 0 else { return "" }
        let lines = logicalLines(text)
        let selected = fromEnd ? Array(lines.suffix(count)) : Array(lines.prefix(count))
        return selected.isEmpty ? "" : selected.joined(separator: "\n") + "\n"
    }

    private static func logicalLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private static func renderPrintf(format: String, arguments: [String]) throws -> String {
        let characters = Array(format)
        var result = ""
        var argumentIndex = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 1
                guard index < characters.count else {
                    throw IOSAmberShellCommandError.usage("printf 格式中的转义未闭合。")
                }
                switch characters[index] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default:
                    throw IOSAmberShellCommandError.usage("printf 仅支持 \\n、\\t 与 \\\\ 转义。")
                }
            } else if character == "%" {
                index += 1
                guard index < characters.count else {
                    throw IOSAmberShellCommandError.usage("printf 格式中的 % 未闭合。")
                }
                switch characters[index] {
                case "%": result.append("%")
                case "s":
                    guard arguments.indices.contains(argumentIndex) else {
                        throw IOSAmberShellCommandError.usage("printf 缺少 %s 参数。")
                    }
                    result += arguments[argumentIndex]
                    argumentIndex += 1
                case "d":
                    guard arguments.indices.contains(argumentIndex),
                          let value = Int(arguments[argumentIndex]) else {
                        throw IOSAmberShellCommandError.usage("printf 的 %d 参数必须是整数。")
                    }
                    result += String(value)
                    argumentIndex += 1
                default:
                    throw IOSAmberShellCommandError.usage("printf 仅支持 %s、%d 与 %% 格式。")
                }
            } else {
                result.append(character)
            }
            index += 1
        }
        guard argumentIndex == arguments.count else {
            throw IOSAmberShellCommandError.usage("printf 参数数量与格式不匹配。")
        }
        return result
    }

    private static func posixBasename(_ raw: String) -> String {
        var value = raw
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        guard value != "/" else { return "/" }
        return value.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "."
    }

    private static func posixDirname(_ raw: String) -> String {
        var value = raw
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        guard let slash = value.lastIndex(of: "/") else { return "." }
        if slash == value.startIndex { return "/" }
        var parent = String(value[..<slash])
        while parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        return parent.isEmpty ? "." : parent
    }

    private static func boundedResult(
        exitCode: Int?,
        stdout: String,
        stderr: String,
        termination: IOSAmberShellTermination? = nil
    ) -> IOSAmberShellCommandResult {
        let boundedStdout = bounded(stdout)
        let boundedStderr = bounded(stderr)
        return IOSAmberShellCommandResult(
            exitCode: exitCode,
            stdout: boundedStdout.value,
            stderr: boundedStderr.value,
            stdoutTruncated: boundedStdout.truncated,
            stderrTruncated: boundedStderr.truncated,
            termination: termination
        )
    }

    private static func bounded(_ value: String) -> (value: String, truncated: Bool) {
        guard value.utf8.count > maxOutputBytes else { return (value, false) }
        var data = Data(value.utf8.prefix(maxOutputBytes))
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty {
            data.removeLast()
        }
        return (String(decoding: data, as: UTF8.self), true)
    }
}

private struct IOSAmberShellStageResult {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

private struct IOSAmberShellProgram {
    let stages: [IOSAmberShellStage]
    let stdinRedirect: String?
    let stdoutRedirect: String?
    let stderrRedirect: String?
}

private struct IOSAmberShellStage {
    let arguments: [String]
}

private enum IOSAmberShellToken: Equatable {
    case word(String)
    case pipe
    case stdinRedirect
    case stdoutRedirect
    case stderrRedirect
}

private enum IOSAmberShellParser {
    private static let environment = [
        "PWD": "/workspace",
        "HOME": "/workspace",
        "LANG": "en_US.UTF-8",
    ]

    static func parse(_ command: String) throws -> IOSAmberShellProgram {
        let tokens = try tokenize(command)
        guard !tokens.isEmpty else {
            throw IOSAmberShellCommandError.usage("需要提供 AmberShell 命令。")
        }

        var stages: [[String]] = [[]]
        var stdinRedirect: String?
        var stdoutRedirect: String?
        var stderrRedirect: String?
        var index = 0

        while index < tokens.count {
            switch tokens[index] {
            case .word(let value):
                stages[stages.count - 1].append(value)
            case .pipe:
                guard !stages[stages.count - 1].isEmpty else {
                    throw IOSAmberShellCommandError.syntax("管道两侧都必须有命令。")
                }
                guard stages.count < 3 else {
                    throw IOSAmberShellCommandError.syntax("AmberShell 最多支持三段 pipeline。")
                }
                stages.append([])
            case .stdinRedirect, .stdoutRedirect, .stderrRedirect:
                guard index + 1 < tokens.count, case .word(let path) = tokens[index + 1] else {
                    throw IOSAmberShellCommandError.syntax("重定向运算符后必须跟一个文件路径。")
                }
                switch tokens[index] {
                case .stdinRedirect:
                    guard stages.count == 1, stdinRedirect == nil else {
                        throw IOSAmberShellCommandError.syntax("< 只能在第一段命令中出现一次。")
                    }
                    stdinRedirect = path
                case .stdoutRedirect:
                    guard stdoutRedirect == nil else {
                        throw IOSAmberShellCommandError.syntax("> 只能出现一次。")
                    }
                    stdoutRedirect = path
                case .stderrRedirect:
                    guard stderrRedirect == nil else {
                        throw IOSAmberShellCommandError.syntax("2> 只能出现一次。")
                    }
                    stderrRedirect = path
                default:
                    break
                }
                index += 1
            }
            index += 1
        }

        guard stages.allSatisfy({ !$0.isEmpty }) else {
            throw IOSAmberShellCommandError.syntax("管道两侧都必须有命令。")
        }
        if stdoutRedirect != nil || stderrRedirect != nil {
            let finalStageIndex = stages.count - 1
            var currentStage = 0
            for token in tokens {
                if token == .pipe { currentStage += 1 }
                if (token == .stdoutRedirect || token == .stderrRedirect), currentStage != finalStageIndex {
                    throw IOSAmberShellCommandError.syntax("> 与 2> 只能用于最后一段命令。")
                }
            }
        }

        return IOSAmberShellProgram(
            stages: stages.map { IOSAmberShellStage(arguments: $0) },
            stdinRedirect: stdinRedirect,
            stdoutRedirect: stdoutRedirect,
            stderrRedirect: stderrRedirect
        )
    }

    private static func tokenize(_ command: String) throws -> [IOSAmberShellToken] {
        guard !command.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw IOSAmberShellCommandError.syntax("AmberShell 单条命令不能包含换行或 NUL。")
        }
        guard !command.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0.value != 9
        }) else {
            throw IOSAmberShellCommandError.syntax("AmberShell 命令不能包含控制字符。")
        }

        let characters = Array(command)
        var tokens: [IOSAmberShellToken] = []
        var current = ""
        var quote: Character?
        var tokenStarted = false
        var currentIsBareStderrPrefix = false
        var index = 0

        func appendCurrent() {
            guard tokenStarted else { return }
            tokens.append(.word(current))
            current = ""
            tokenStarted = false
            currentIsBareStderrPrefix = false
        }

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\" {
                    index += 1
                    guard index < characters.count else {
                        throw IOSAmberShellCommandError.syntax("命令中的转义未闭合。")
                    }
                    let escaped = characters[index]
                    if escaped == "$" || escaped == "\"" || escaped == "\\" {
                        current.append(escaped)
                    } else {
                        current.append("\\")
                        current.append(escaped)
                    }
                    tokenStarted = true
                    currentIsBareStderrPrefix = false
                } else if activeQuote == "\"", character == "$" {
                    let expansion = try expandedVariable(in: characters, dollarIndex: index)
                    current += expansion.value
                    index = expansion.lastIndex
                    tokenStarted = true
                    currentIsBareStderrPrefix = false
                } else {
                    current.append(character)
                    tokenStarted = true
                    currentIsBareStderrPrefix = false
                }
            } else if character == "'" || character == "\"" {
                quote = character
                tokenStarted = true
                currentIsBareStderrPrefix = false
            } else if character == "\\" {
                index += 1
                guard index < characters.count else {
                    throw IOSAmberShellCommandError.syntax("命令中的转义未闭合。")
                }
                current.append(characters[index])
                tokenStarted = true
                currentIsBareStderrPrefix = false
            } else if character.isWhitespace {
                appendCurrent()
            } else if character == "|" {
                appendCurrent()
                tokens.append(.pipe)
            } else if character == "<" {
                appendCurrent()
                tokens.append(.stdinRedirect)
            } else if character == ">" {
                if current == "2", currentIsBareStderrPrefix {
                    current = ""
                    tokenStarted = false
                    currentIsBareStderrPrefix = false
                    tokens.append(.stderrRedirect)
                } else {
                    appendCurrent()
                    tokens.append(.stdoutRedirect)
                }
            } else if character == "$" {
                let expansion = try expandedVariable(in: characters, dollarIndex: index)
                current += expansion.value
                index = expansion.lastIndex
                tokenStarted = true
                currentIsBareStderrPrefix = false
            } else if "&;`".contains(character) {
                throw IOSAmberShellCommandError.syntax("AmberShell 不支持控制流或命令替换。")
            } else if "*?[]~".contains(character) {
                throw IOSAmberShellCommandError.syntax("AmberShell 不支持 glob 或 tilde 展开。")
            } else {
                currentIsBareStderrPrefix = !tokenStarted && character == "2"
                current.append(character)
                tokenStarted = true
            }
            index += 1
        }

        guard quote == nil else {
            throw IOSAmberShellCommandError.syntax("命令中的引号未闭合。")
        }
        appendCurrent()
        return tokens
    }

    private static func expandedVariable(
        in characters: [Character],
        dollarIndex: Int
    ) throws -> (value: String, lastIndex: Int) {
        let start = dollarIndex + 1
        guard start < characters.count else {
            throw IOSAmberShellCommandError.syntax("$ 后必须是受支持的环境变量名。")
        }
        if characters[start] == "(" {
            throw IOSAmberShellCommandError.syntax("AmberShell 不支持命令替换。")
        }

        let name: String
        let lastIndex: Int
        if characters[start] == "{" {
            var end = start + 1
            while end < characters.count, characters[end] != "}" { end += 1 }
            guard end < characters.count else {
                throw IOSAmberShellCommandError.syntax("环境变量的 } 未闭合。")
            }
            name = String(characters[(start + 1)..<end])
            lastIndex = end
        } else {
            var end = start
            while end < characters.count, isVariableCharacter(characters[end], first: end == start) {
                end += 1
            }
            guard end > start else {
                throw IOSAmberShellCommandError.syntax("$ 后必须是受支持的环境变量名。")
            }
            name = String(characters[start..<end])
            lastIndex = end - 1
        }
        guard let value = environment[name] else {
            throw IOSAmberShellCommandError.syntax("AmberShell 不支持环境变量 $\(name)。")
        }
        return (value, lastIndex)
    }

    private static func isVariableCharacter(_ character: Character, first: Bool) -> Bool {
        if character == "_" { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        if CharacterSet.letters.contains(scalar) { return true }
        return !first && CharacterSet.decimalDigits.contains(scalar)
    }
}

private enum IOSAmberShellCommandError: LocalizedError {
    case usage(String)
    case syntax(String)
    case unsupported(String)

    var exitCode: Int {
        switch self {
        case .unsupported: 127
        case .usage, .syntax: 64
        }
    }

    var errorDescription: String? {
        switch self {
        case .usage(let message), .syntax(let message):
            message
        case .unsupported(let command):
            "AmberShell 当前不支持命令：\(command)。可用命令：\(IOSAmberShellEngine.supportedCommands.joined(separator: ", "))。"
        }
    }
}
