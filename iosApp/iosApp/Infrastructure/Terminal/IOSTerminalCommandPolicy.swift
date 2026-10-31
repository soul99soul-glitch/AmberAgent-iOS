import Foundation
@preconcurrency import Shared

enum IOSRemoteCommandPolicyResult {
    case success(String)
    case failure(String)
}

enum IOSRemoteCommandPolicy {
    static func validate(_ command: String) -> IOSRemoteCommandPolicyResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Command is required.")
        }
        guard trimmed.count <= 2_000 else {
            return .failure("Command is too long for a single remote execution task.")
        }

        let lowercased = trimmed.lowercased()
        let blockedFragments = [
            "rm -rf /",
            "mkfs",
            "diskutil erase",
            "shutdown",
            "reboot",
            ":(){",
            "dd if=",
            ">:",
            "chmod -r 777 /"
        ]
        if let fragment = blockedFragments.first(where: { lowercased.contains($0) }) {
            return .failure("Blocked potentially destructive command fragment: \(fragment)")
        }
        return .success(trimmed)
    }
}

/// Embedded iSH runs inside an app-owned guest, so it intentionally accepts
/// larger scripts and ordinary guest writes. Keep only a short accidental
/// root-destruction guard here; explicit per-launch approval remains the main
/// policy boundary.
enum IOSEmbeddedIshCommandPolicy {
    static let maxCommandLength = 32_000

    static func validate(_ command: String) -> IOSRemoteCommandPolicyResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Command is required.")
        }
        guard trimmed.count <= maxCommandLength else {
            return .failure("Embedded iSH scripts are limited to \(maxCommandLength) characters.")
        }

        let blockedPatterns = [
            #"(?i)\brm\s+(?=[^\n;]*(?:-(?:[a-z-]*r[a-z-]*f|[a-z-]*f[a-z-]*r)\b|--recursive\b[^\n;]*--force\b|--force\b[^\n;]*--recursive\b))[^\n;]*?\s(?:--\s+)?['\"]?/(?:['\"]?|\*|\.\??\*)\s*(?:$|[;&|])"#,
            #"(?i)\bfind\s+['\"]?/['\"]?\s+[^\n;]*-delete\b"#,
            #"(?i)\b(?:mkfs(?:\.[a-z0-9_-]+)?|shutdown|reboot|poweroff|halt)\b"#,
            #"(?i)\binit\s+0\b"#,
            #"(?i)\bkill\s+(?:-9|-kill)\s+1\b"#,
            #"(?i):\s*\(\s*\)\s*\{[^\n]*:\s*\|\s*:"#,
        ]
        if blockedPatterns.contains(where: {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }) {
            return .failure("Blocked a command that can destroy or stop the embedded iSH guest root environment.")
        }
        return .success(command)
    }
}

enum IOSPOSIXWorkingDirectory {
    static let embeddedDefault = "/workspace"

    static func normalized(_ value: String?, default defaultValue: String? = nil) throws -> String? {
        guard let rawValue = value?.nilIfBlank ?? defaultValue else { return nil }
        let path = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.first == "/" else {
            throw IOSPOSIXWorkingDirectoryError.notAbsolute
        }
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw IOSPOSIXWorkingDirectoryError.containsControlCharacters
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw IOSPOSIXWorkingDirectoryError.notCanonical
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func remoteCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory else { return command }
        return "cd \(shellQuote(workingDirectory)) && \(command)"
    }

    static func embeddedCommand(_ command: String, workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && exec /bin/sh -lc \(shellQuote(command))"
    }
}

enum IOSPOSIXWorkingDirectoryError: LocalizedError {
    case notAbsolute
    case containsControlCharacters
    case notCanonical

    var errorDescription: String? {
        switch self {
        case .notAbsolute:
            "Working directory must be an absolute POSIX path."
        case .containsControlCharacters:
            "Working directory cannot contain NUL or line breaks."
        case .notCanonical:
            "Working directory cannot contain . or .. path components."
        }
    }
}

/// SSH backends sanitize stdout/stderr before buffering or truncating it.
/// Runtime errors are sanitized again at the job boundary before persistence.

func remoteSSHTargetDigest(_ profile: IOSSSHProfile) -> String {
    remoteSSHTargetDigest(route: [profile])
}

func remoteSSHTargetDigest(route: [IOSSSHProfile]) -> String {
    let serializedHops = route.map { profile in
        [
            profile.id,
            profile.authMethod.rawValue,
            profile.keyId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            profile.jumpProfileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
            profile.host.trimmingCharacters(in: .whitespacesAndNewlines),
            String(profile.port),
            profile.knownHostSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            profile.knownHostHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            profile.knownHostPort.map(String.init) ?? "",
            profile.knownHostViaJump?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "\n")
    }.joined(separator: "\n---\n")
    return chatInputDigest(for: serializedHops)
}
