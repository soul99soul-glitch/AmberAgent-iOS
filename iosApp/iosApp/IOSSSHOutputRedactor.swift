import Foundation

/// Redacts SSH credentials from output before it can reach a tool result or a
/// persisted task record. Each stdout/stderr channel has an independent
/// carry buffer so a split secret on one channel cannot affect the other.
///
/// The instance is safe for concurrent output callbacks. It deliberately
/// keeps only a bounded carry buffer; an unterminated private-key block is
/// suppressed after the bound is reached and remains suppressed until its end
/// marker or `finish()`.
final class IOSSSHOutputRedactor: @unchecked Sendable {
    static let replacement = "[redacted]"

    private static let maxBufferedBytes = 128 * 1024
    private static let maxCredentialBytes = 64 * 1024
    private static let beginPrefix = "-----BEGIN "
    private static let endPrefix = "-----END "

    private struct ChannelState {
        var pending = ""
        var suppressingPrivateKey = false
    }

    private let lock = NSLock()
    private let credentialSecret: String?
    private var stdout = ChannelState()
    private var stderr = ChannelState()
    private var didFinish = false

    init(credential: IOSSSHCredential) {
        let secret = credential.secret
        if secret.isEmpty || secret.utf8.count > Self.maxCredentialBytes {
            credentialSecret = nil
        } else {
            credentialSecret = secret
        }
    }

    /// Redacts one output chunk. `nil` means that the chunk is being held
    /// until a cross-chunk secret or private-key boundary is resolved.
    func redact(_ chunk: IOSSSHOutputChunk) -> IOSSSHOutputChunk? {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return nil }

        let text: String
        if chunk.isStderr {
            text = process(chunk.text, state: &stderr, finishing: false)
        } else {
            text = process(chunk.text, state: &stdout, finishing: false)
        }
        guard !text.isEmpty else { return nil }
        return IOSSSHOutputChunk(text: text, isStderr: chunk.isStderr)
    }

    /// Flushes safe carry text. An incomplete private-key block is discarded
    /// as a redacted block; a partial password prefix is safe to emit because
    /// the complete credential was never observed.
    func finish() -> [IOSSSHOutputChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return [] }
        didFinish = true

        var result: [IOSSSHOutputChunk] = []
        let stdoutText = process("", state: &stdout, finishing: true)
        if !stdoutText.isEmpty {
            result.append(IOSSSHOutputChunk(text: stdoutText, isStderr: false))
        }
        let stderrText = process("", state: &stderr, finishing: true)
        if !stderrText.isEmpty {
            result.append(IOSSSHOutputChunk(text: stderrText, isStderr: true))
        }
        return result
    }

    /// Redacts a final result or error in one call. The same PEM and exact
    /// credential rules apply even when the caller has no stream boundaries.
    static func redact(_ string: String, credential: IOSSSHCredential) -> String {
        guard !string.isEmpty else { return string }
        let redactor = IOSSSHOutputRedactor(credential: credential)
        var output = ""
        if let chunk = redactor.redact(IOSSSHOutputChunk(text: string, isStderr: false)) {
            output += chunk.text
        }
        output += redactor.finish()
            .filter { !$0.isStderr }
            .map(\.text)
            .joined()
        return output
    }

    private func process(
        _ text: String,
        state: inout ChannelState,
        finishing: Bool
    ) -> String {
        if !text.isEmpty {
            state.pending.append(text)
        }

        var pieces: [String] = []
        while true {
            if state.suppressingPrivateKey {
                if let end = privateKeyEndRange(in: state.pending) {
                    state.pending.removeSubrange(..<end.upperBound)
                    state.suppressingPrivateKey = false
                    continue
                }
                if let markerStart = possiblePEMMarkerStart(in: state.pending, prefix: Self.endPrefix) {
                    state.pending = String(state.pending[markerStart...])
                } else {
                    state.pending.removeAll(keepingCapacity: true)
                }
                break
            }

            let passwordRange = credentialSecret.flatMap { state.pending.range(of: $0) }
            let beginRange = privateKeyBeginRange(in: state.pending)
            guard let candidate = earliest(passwordRange, beginRange) else {
                if finishing {
                    if let privateStart = possiblePrivateKeyBeginStart(in: state.pending) {
                        pieces.append(String(state.pending[..<privateStart]))
                        pieces.append(Self.replacement)
                        state.pending.removeAll(keepingCapacity: true)
                        state.suppressingPrivateKey = true
                    } else {
                        pieces.append(state.pending)
                        state.pending.removeAll(keepingCapacity: true)
                    }
                    break
                }

                let holdStart = safeHoldStart(in: state.pending)
                if let holdStart,
                   state.pending.distance(from: holdStart, to: state.pending.endIndex) > 0 {
                    pieces.append(String(state.pending[..<holdStart]))
                    state.pending = String(state.pending[holdStart...])
                } else if holdStart == nil {
                    pieces.append(state.pending)
                    state.pending.removeAll(keepingCapacity: true)
                }

                if state.pending.utf8.count > Self.maxBufferedBytes,
                   let privateStart = possiblePrivateKeyBeginStart(in: state.pending) {
                    pieces.append(String(state.pending[..<privateStart]))
                    pieces.append(Self.replacement)
                    state.pending.removeAll(keepingCapacity: true)
                    state.suppressingPrivateKey = true
                }
                break
            }

            pieces.append(String(state.pending[..<candidate.lowerBound]))
            if let passwordRange, candidate == passwordRange {
                pieces.append(Self.replacement)
                state.pending.removeSubrange(..<candidate.upperBound)
            } else {
                pieces.append(Self.replacement)
                state.pending.removeSubrange(..<candidate.upperBound)
                state.suppressingPrivateKey = true
            }
        }
        return pieces.joined()
    }

    private func safeHoldStart(in text: String) -> String.Index? {
        var starts: [String.Index] = []
        if let secret = credentialSecret,
           let start = suffixPrefixStart(text, prefix: secret) {
            starts.append(start)
        }
        if let start = possiblePrivateKeyBeginStart(in: text) {
            starts.append(start)
        }
        return starts.min()
    }

    private func suffixPrefixStart(_ text: String, prefix: String) -> String.Index? {
        guard !prefix.isEmpty, !text.isEmpty else { return nil }
        let maximum = min(prefix.count - 1, text.count)
        guard maximum > 0 else { return nil }
        for length in stride(from: maximum, through: 1, by: -1) {
            let start = text.index(text.endIndex, offsetBy: -length)
            if prefix.hasPrefix(String(text[start...])) {
                return start
            }
        }
        return nil
    }

    private func earliest(
        _ lhs: Range<String.Index>?,
        _ rhs: Range<String.Index>?
    ) -> Range<String.Index>? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let range?, nil), (nil, let range?): range
        case (let left?, let right?):
            left.lowerBound <= right.lowerBound ? left : right
        }
    }

    private func privateKeyBeginRange(in text: String) -> Range<String.Index>? {
        completePEMRange(in: text, prefix: Self.beginPrefix)
    }

    private func privateKeyEndRange(in text: String) -> Range<String.Index>? {
        completePEMRange(in: text, prefix: Self.endPrefix)
    }

    private func completePEMRange(
        in text: String,
        prefix: String
    ) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let marker = text.range(of: prefix, range: searchStart..<text.endIndex) {
            guard let delimiter = text.range(of: "-----", range: marker.upperBound..<text.endIndex) else {
                return nil
            }
            let label = String(text[marker.upperBound..<delimiter.lowerBound])
            if Self.isPrivateKeyLabel(label) {
                return marker.lowerBound..<delimiter.upperBound
            }
            searchStart = delimiter.upperBound
        }
        return nil
    }

    private func possiblePrivateKeyBeginStart(in text: String) -> String.Index? {
        possiblePEMMarkerStart(in: text, prefix: Self.beginPrefix)
    }

    private func possiblePEMMarkerStart(in text: String, prefix: String) -> String.Index? {
        var searchStart = text.startIndex
        var possible: String.Index?
        while let marker = text.range(of: prefix, range: searchStart..<text.endIndex) {
            let suffix = text[marker.upperBound...]
            if suffix.unicodeScalars.allSatisfy(Self.isPEMLabelScalar) {
                possible = marker.lowerBound
            }
            searchStart = marker.upperBound
        }
        if let possible { return possible }
        return suffixPrefixStart(text, prefix: prefix)
    }

    private static func isPrivateKeyLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasSuffix("PRIVATE KEY") &&
            normalized.unicodeScalars.allSatisfy(isPEMLabelScalar)
    }

    private static func isPEMLabelScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar == " " || scalar == "_" || scalar == "-" ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }
}
