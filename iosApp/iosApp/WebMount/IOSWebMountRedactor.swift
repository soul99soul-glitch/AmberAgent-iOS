import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum IOSWebMountRedactor {
    static func redactCredentialGroups(in result: inout [String: Any], keys: [String]) -> Bool {
        var redacted = false
        for key in keys {
            guard let value = result[key] as? String else { continue }
            let (cleaned, didRedact) = redactedCredentialGroups(value)
            result[key] = cleaned
            redacted = redacted || didRedact
        }
        return redacted
    }

    static func redactedCredentialGroups(_ text: String) -> (String, Bool) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var redacted = false
        var credentialHeading = false
        while index < lines.count {
            let line = lines[index]
            if isCredentialHeading(line) {
                output.append(line)
                credentialHeading = true
                index += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(line)
                index += 1
                continue
            }
            guard looksLikeCredentialLine(line, credentialHeading: credentialHeading) else {
                output.append(line)
                credentialHeading = false
                index += 1
                continue
            }
            let start = index
            while index < lines.count && looksLikeCredentialLine(lines[index], credentialHeading: credentialHeading) { index += 1 }
            let count = index - start
            if count >= 2 {
                output.append("[已隐去 \(count) 行疑似凭据]")
                redacted = true
            } else {
                output.append(lines[start])
            }
            credentialHeading = false
        }
        return (redacted ? output.joined(separator: "\n") : text, redacted)
    }

    private static func isCredentialHeading(_ line: String) -> Bool {
        line.range(
            of: #"(?i)^\s*(?:(?:recovery|backup)\s+codes?|(?:api|access)\s+(?:keys?|tokens?)|tokens?)\s*:?\s*$|^\s*(?:恢复码|备份码|API密钥|访问令牌)\s*[:：]?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeCredentialLine(_ line: String, credentialHeading: Bool) -> Bool {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitCredentialLabel = value.range(
            of: #"(?i)^(?:(?:(?:api|access)[ _-]?)?(?:key|token)|recovery[ _-]?code|恢复码|密钥)\s*\d*\s*[:：=]\s*"#,
            options: .regularExpression
        ) != nil
        value = value.replacingOccurrences(
            of: #"(?i)^(?:\d+[.)]\s*|(?:(?:(?:api|access)[ _-]?)?(?:key|token)|recovery[ _-]?code|恢复码|密钥)\s*\d*\s*[:：=]\s*)"#,
            with: "",
            options: .regularExpression
        )
        guard value.count >= 20, value.count <= 160,
              value.range(of: #"^[A-Za-z0-9_+/=.\- ]+$"#, options: .regularExpression) != nil else {
            return false
        }
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard Set(compact).count >= 8 else { return false }
        let isDigest = [32, 40, 64, 96, 128].contains(compact.count)
            && compact.range(of: #"^[A-Fa-f0-9]+$"#, options: .regularExpression) != nil
        guard !isDigest || explicitCredentialLabel || credentialHeading else { return false }
        let hasLetters = compact.rangeOfCharacter(from: .letters) != nil
        let hasDigits = compact.rangeOfCharacter(from: .decimalDigits) != nil
        let recoveryCode = value.range(of: #"^(?:[A-Za-z0-9]{4,8}[- ]){2,}[A-Za-z0-9]{4,8}$"#, options: .regularExpression) != nil
        let length = Double(compact.count)
        let entropy = Dictionary(grouping: compact, by: { $0 }).values.reduce(0.0) { sum, group in
            let fraction = Double(group.count) / length
            return sum - fraction * log2(fraction)
        }
        return recoveryCode || (hasLetters && hasDigits && !value.contains(" ") && entropy >= 3.7)
    }

    static func redactedURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.nilIfBlank != nil else {
            return "[redacted-url]"
        }
        var safe = URLComponents()
        safe.scheme = scheme
        safe.host = components.host
        safe.port = components.port
        let path = components.path.isEmpty ? "/" : components.path
        let sensitivePathMarkers = [
            "token", "oauth", "callback", "verify", "verification", "reset",
            "recovery", "magic", "authorize", "authentication", "session"
        ]
        safe.path = sensitivePathMarkers.contains(where: { path.lowercased().contains($0) })
            ? "/redacted"
            : path
        return safe.string
    }

    static func redactedJSONObject(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, item) in dict {
                let loweredKey = key.lowercased()
                if isSensitiveKey(loweredKey) {
                    redacted[key] = "***redacted***"
                } else if loweredKey.contains("url") || loweredKey == "href" || loweredKey == "src",
                          let string = item as? String {
                    redacted[key] = redactedURL(string) ?? string
                } else {
                    redacted[key] = redactedJSONObject(item)
                }
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map(redactedJSONObject)
        }
        if let string = value as? String {
            return redactedText(string)
        }
        return value
    }

    static func redactedText(_ value: String) -> String {
        var output = value
        output = replacingMatches(
            in: output,
            pattern: #"https?://[^\s"'<>)]+"#,
            options: [.caseInsensitive]
        ) { match in
            redactedURL(match) ?? "[redacted-url]"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{6,}"#
        ) { _ in
            "Bearer ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)["']?\b(authorization|auth|token|access_token|refresh_token|auth_token|csrf|xsrf|session|secret|password|passcode|otp|totp|mfa|2fa|captcha|card_number|card.?number|pan|cvv|cvc|security.?code|payment|billing)["']?\s*[:=]\s*["']?[^&,\s"'<>)}\]]+"#,
            options: [.caseInsensitive]
        ) { match in
            let separatorIndex = match.firstIndex(where: { $0 == ":" || $0 == "=" })
            let prefix = separatorIndex.map { String(match[...$0]) } ?? "secret:"
            return "\(prefix) ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)(\b(?:otp|totp|mfa|2fa|passcode|verification\s*code|security\s*code|captcha)\b|验证码|校验码|动态码)\s*[:：=\-]?\s*\d{4,10}"#
        ) { match in
            let label = match.prefix { !$0.isNumber }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label) ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)(\b(?:card(?:\s*number)?|credit\s*card|pan|cvv|cvc|security\s*code)\b|卡号|安全码)\s*[:：=\-]?\s*(?:\d[\s-]?){3,19}"#
        ) { match in
            let label = match.prefix { !$0.isNumber }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label) ***redacted***"
        }
        return output
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let compact = String(key.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        if [
            "authorization", "auth", "token", "accesstoken", "refreshtoken", "authtoken",
            "cookie", "secret", "password", "passcode", "otp", "otpcode", "totp", "mfa", "2fa",
            "captcha", "verificationcode", "card", "cardnumber", "pan", "cvv", "cvv2", "cvc",
            "securitycode", "payment", "billing", "billingaddress"
        ].contains(compact) || ["验证码", "校验码", "动态码", "卡号", "安全码"].contains(where: compact.contains) {
            return true
        }
        return compact.hasSuffix("token") ||
            compact.hasSuffix("secret") ||
            compact.hasSuffix("password") ||
            compact.hasSuffix("otp") ||
            (compact.hasSuffix("code") && [
                "verification", "security", "mfa", "2fa", "captcha"
            ].contains { compact.contains($0) }) ||
            compact.hasSuffix("card") ||
            compact.hasSuffix("pan") ||
            compact.hasSuffix("cvv") ||
            compact.hasSuffix("cvc")
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }
        var output = value
        for match in matches.reversed() {
            let original = nsValue.substring(with: match.range)
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: transform(original))
            }
        }
        return output
    }
}

