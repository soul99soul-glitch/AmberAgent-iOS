#if ENABLE_AMBERSHELL_PYTHON

import Foundation

struct AmberShellPythonExecutionResult: Equatable, Sendable {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

/// Stable CPython 3.14 execution for AmberShell's restricted Python command.
/// This is an embedded runtime boundary, not a security sandbox. Cancellation
/// and deadlines interrupt Python bytecode cooperatively; a blocking native C
/// extension cannot be force-terminated.
actor AmberShellPythonRuntime {
    static let shared = AmberShellPythonRuntime()

    private static let maxStdinBytes = 64 * 1024

    private init() {}

    func execute(
        source: String,
        stdin: String,
        control: IOSAmberShellExecutionControl?
    ) throws -> AmberShellPythonExecutionResult {
        try control?.checkpoint()
        let stdinData = Data(stdin.utf8)
        guard stdinData.count <= Self.maxStdinBytes else {
            return AmberShellPythonExecutionResult(
                exitCode: 2,
                stdout: "",
                stderr: "AmberShell Python stdin cannot exceed 65536 UTF-8 bytes.\n"
            )
        }

        let resourcePath = Self.bundleResourcePath()
        let appPath = URL(fileURLWithPath: resourcePath, isDirectory: true)
            .appendingPathComponent("AmberShellPythonApp", isDirectory: true)
            .path
        let sourceData = Data(source.utf8)
        var cResult = AmberShellPythonBridgeResult()

        let status: Int32 = resourcePath.withCString { resourceCString in
            appPath.withCString { appCString in
                sourceData.withUnsafeBytes { sourceBuffer in
                    stdinData.withUnsafeBytes { stdinBuffer in
                        amber_shell_python_execute(
                            resourceCString,
                            appCString,
                            sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            sourceBuffer.count,
                            stdinBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            stdinBuffer.count,
                            control?.opaquePointer,
                            &cResult
                        )
                    }
                }
            }
        }
        defer {
            amber_shell_python_execution_result_dispose(&cResult)
        }
        try control?.checkpoint()

        let stdout = Self.decode(cResult.stdout_bytes, length: cResult.stdout_length)
        let stderr = Self.decode(cResult.stderr_bytes, length: cResult.stderr_length)
        guard status == 0 else {
            let message = cResult.error_message.map { String(cString: $0) }
                ?? "Unable to execute the embedded CPython runtime."
            return AmberShellPythonExecutionResult(
                exitCode: cResult.exit_code == 0 ? 74 : Int(cResult.exit_code),
                stdout: stdout,
                stderr: stderr.isEmpty ? message + "\n" : stderr
            )
        }

        return AmberShellPythonExecutionResult(
            exitCode: Int(cResult.exit_code),
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func bundleResourcePath() -> String {
        Bundle.main.resourceURL?.path ?? Bundle.main.bundlePath
    }

    private static func decode(
        _ bytes: UnsafeMutablePointer<UInt8>?,
        length: Int
    ) -> String {
        guard let bytes, length > 0 else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: length),
            as: UTF8.self
        )
    }
}

#endif
