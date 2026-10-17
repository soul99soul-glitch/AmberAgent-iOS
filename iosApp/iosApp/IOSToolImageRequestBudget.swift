import Foundation
import ImageIO
@preconcurrency import Shared

/// Request-only budget for images inside tool results (phone screenshots, page captures).
///
/// Every model step re-sends the whole history, so a 50-step phone run used to upload
/// every screenshot again on each step. Only the latest `keepRecentToolResults` tool
/// results that carry real images keep them; older ones get a deterministic text
/// placeholder while their text output stays. The persisted conversation is never touched.
///
/// Prefix stability: tool results are only ever appended, so the kept window only moves
/// forward. A result loses its image once and keeps the same placeholder in every later
/// round. Results that already carry a placeholder (e.g. a background continuation of an
/// edited view) or a missing blob still count toward the step ordinal, so numbering does
/// not shift.
///
/// Missing blobs: storage resolves a lost screenshot blob to a 1x1 PNG placeholder
/// (`isMissingBlobPlaceholder()`, marker metadata or placeholder url). At any depth inside
/// tool results it is always sent as `missingBlobText` and never occupies the kept window.
///
/// Images attached by the user (or generated into message parts) are top-level message
/// parts, not tool outputs, and are never changed.
enum IOSToolImageRequestBudget {
    static let keepRecentToolResults = 2
    static let placeholderPrefix = "[较早的截图已省略"
    static var missingBlobMetadataKey: String { ConversationBlobsKt.MISSING_BLOB_METADATA_KEY }
    static let missingBlobText = "[截图文件缺失]"

    static func placeholderText(step: Int) -> String {
        "\(placeholderPrefix)：第 \(step) 步]"
    }

    /// Storage contract (ConversationBlobs.kt): marker metadata OR the placeholder url, so it
    /// still holds after an upper layer rebuilt the part with `metadata: nil`.
    static func isMissingBlobPlaceholder(_ image: UIMessagePart.Image) -> Bool {
        image.isMissingBlobPlaceholder()
    }

    private enum Kind { case image, dropped, missingOnly }

    static func apply(_ messages: [UIMessage], keepRecent: Int = keepRecentToolResults) -> [UIMessage] {
        Memo.shared.recordRun()
        // Every tool result that has (or had) a screenshot, in transcript order.
        var located: [(message: Int, part: Int, kind: Kind, hasMissing: Bool)] = []
        for (messageIndex, message) in messages.enumerated() {
            for (partIndex, part) in message.parts.enumerated() {
                guard let tool = part as? UIMessagePart.Tool else { continue }
                let scan = scan(tool.output)
                if scan.real {
                    located.append((messageIndex, partIndex, .image, scan.missing))
                } else if scan.missing {
                    located.append((messageIndex, partIndex, .missingOnly, true))
                } else if scan.placeholder {
                    located.append((messageIndex, partIndex, .dropped, false))
                }
            }
        }
        // The kept window holds the latest results with real images only.
        let imageOrdinals = located.indices.filter { located[$0].kind == .image }
        let kept = Set(imageOrdinals.suffix(max(keepRecent, 0)))

        var replacements: [Int: [Int: String?]] = [:] // message -> part -> placeholder (nil: missing only)
        for (ordinal, entry) in located.enumerated() {
            switch entry.kind {
            case .image where !kept.contains(ordinal):
                replacements[entry.message, default: [:]][entry.part] = .some(placeholderText(step: ordinal + 1))
            case .image where entry.hasMissing, .missingOnly:
                replacements[entry.message, default: [:]][entry.part] = .some(nil)
            default:
                break
            }
        }
        guard !replacements.isEmpty else { return messages }

        return messages.enumerated().map { messageIndex, message in
            guard let parts = replacements[messageIndex] else { return message }
            let newParts: [UIMessagePart] = message.parts.enumerated().map { partIndex, part in
                guard let placeholder = parts[partIndex], let tool = part as? UIMessagePart.Tool else { return part }
                return Memo.shared.transformed(tool, placeholder: placeholder)
            }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: newParts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    /// Same result as `apply`, reused while the transcript is unchanged (identical message
    /// objects). For hot read-only paths such as the context gauge, which renders on every
    /// stream delta and keystroke.
    static func memoizedApply(_ messages: [UIMessage]) -> [UIMessage] {
        Memo.shared.budgeted(messages)
    }

    static func containsImage(_ parts: [UIMessagePart]) -> Bool {
        scan(parts).real
    }

    private static func scan(_ parts: [UIMessagePart]) -> (real: Bool, missing: Bool, placeholder: Bool) {
        var result = (real: false, missing: false, placeholder: false)
        for part in parts {
            if let image = part as? UIMessagePart.Image {
                if isMissingBlobPlaceholder(image) { result.missing = true } else { result.real = true }
            } else if let text = part as? UIMessagePart.Text {
                if text.text.hasPrefix(placeholderPrefix) || text.text == missingBlobText { result.placeholder = true }
            } else if let tool = part as? UIMessagePart.Tool {
                let nested = scan(tool.output)
                result.real = result.real || nested.real
                result.missing = result.missing || nested.missing
                result.placeholder = result.placeholder || nested.placeholder
            }
        }
        return result
    }

    /// Missing blobs always become `missingBlobText`; real images become `placeholder` when given.
    fileprivate static func replacingImages(in tool: UIMessagePart.Tool, placeholder: String?) -> UIMessagePart.Tool {
        let output = tool.output.map { part -> UIMessagePart in
            if let image = part as? UIMessagePart.Image {
                if isMissingBlobPlaceholder(image) { return UIMessagePart.Text(text: missingBlobText, metadata: nil) }
                if let placeholder { return UIMessagePart.Text(text: placeholder, metadata: nil) }
                return part
            }
            if let nested = part as? UIMessagePart.Tool {
                let scan = scan(nested.output)
                if scan.missing || (scan.real && placeholder != nil) {
                    return replacingImages(in: nested, placeholder: placeholder)
                }
            }
            return part
        }
        // copyTool keeps the Kotlin metadata (prompt transcript events) intact.
        return PromptTranscript.shared.doCopyTool(tool: tool, input: tool.input, output: output)
    }

    /// Identity caches so repeated budgeting hands back the same Kotlin objects: the
    /// identity-keyed token estimate memo keeps hitting, and an unchanged transcript is
    /// not re-scanned at all. KMP parts and messages are immutable, so identity is content.
    fileprivate final class Memo: @unchecked Sendable {
        static let shared = Memo()

        private final class ToolEntry: NSObject {
            let placeholder: String?
            let result: UIMessagePart.Tool
            init(placeholder: String?, result: UIMessagePart.Tool) {
                self.placeholder = placeholder
                self.result = result
            }
        }

        private let lock = NSLock()
        private var runs = 0
        private var lastInput: [UIMessage] = []
        private var lastOutput: [UIMessage] = []
        private let tools = NSMapTable<UIMessagePart.Tool, ToolEntry>(
            keyOptions: [.weakMemory, .objectPointerPersonality],
            valueOptions: .strongMemory
        )

        var runCount: Int { lock.withLock { runs } }

        func recordRun() { lock.withLock { runs += 1 } }

        func transformed(_ tool: UIMessagePart.Tool, placeholder: String?) -> UIMessagePart.Tool {
            if let entry = lock.withLock({ tools.object(forKey: tool) }), entry.placeholder == placeholder {
                return entry.result
            }
            let result = IOSToolImageRequestBudget.replacingImages(in: tool, placeholder: placeholder)
            lock.withLock { tools.setObject(ToolEntry(placeholder: placeholder, result: result), forKey: tool) }
            return result
        }

        func budgeted(_ messages: [UIMessage]) -> [UIMessage] {
            let cached: [UIMessage]? = lock.withLock {
                guard lastInput.count == messages.count,
                      zip(lastInput, messages).allSatisfy({ $0 === $1 }) else { return nil }
                return lastOutput
            }
            if let cached { return cached }
            let output = IOSToolImageRequestBudget.apply(messages)
            lock.withLock {
                lastInput = messages
                lastOutput = output
            }
            return output
        }
    }

#if DEBUG
    /// Number of full `apply` passes so far (spy for the gauge memo test).
    static var applyRunCountForTesting: Int { Memo.shared.runCount }
#endif
}

/// Token estimate for one image, consistent with how providers bill images.
///
/// A flat guess hid the real cost of full-resolution screenshots. Pixel size is read from
/// the image header (only a base64 prefix is decoded) and priced as the most expensive of:
/// - Anthropic: resized to <= 1568 px long edge and <= 1.15 MP, tokens = w * h / 750
/// - OpenAI high detail: fit 2048 square, short side <= 768, 85 + 170 per 512 px tile
/// - Gemini: 258 per 768 px tile (258 total when both sides <= 384)
/// The payload term keeps oversized encodings visible to the budget even when their
/// pixel cost is capped by provider resizing.
enum IOSImageTokenEstimate {
    static let unknownImageTokens = 1_600
    /// Decoded bytes per estimated token for the payload floor.
    static let payloadBytesPerToken = 400
    private static let headerPrefixBase64Chars = 87_380 // ~64 KB decoded; multiple of 4

    static func estimatedTokens(url: String) -> Int {
        guard url.hasPrefix("data:"), let marker = url.range(of: ";base64,") else { return unknownImageTokens }
        let payload = url[marker.upperBound...]
        let payloadBytes = payload.utf8.count * 3 / 4
        let payloadTokens = payloadBytes / payloadBytesPerToken
        guard let size = pixelSize(base64: payload) else { return max(unknownImageTokens, payloadTokens) }
        return max(providerTokens(width: size.width, height: size.height), payloadTokens)
    }

    static func pixelSize(base64 payload: Substring) -> (width: Int, height: Int)? {
        let prefixLength = min(payload.utf8.count, headerPrefixBase64Chars) / 4 * 4
        guard prefixLength > 0,
              let data = Data(base64Encoded: String(payload.utf8.prefix(prefixLength)) ?? "",
                              options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func providerTokens(width: Int, height: Int) -> Int {
        let w = Double(width), h = Double(height)
        let claudeScale = min(1, 1_568 / max(w, h), (1_150_000 / (w * h)).squareRoot())
        let claude = Int((w * claudeScale * h * claudeScale / 750).rounded(.up))

        let fit = min(1, 2_048 / max(w, h))
        let shortScale = min(1, 768 / (min(w, h) * fit))
        let ow = w * fit * shortScale, oh = h * fit * shortScale
        let openAI = 85 + 170 * Int((ow / 512).rounded(.up)) * Int((oh / 512).rounded(.up))

        let gemini = (width <= 384 && height <= 384)
            ? 258
            : 258 * Int((w / 768).rounded(.up)) * Int((h / 768).rounded(.up))

        return max(claude, openAI, gemini)
    }
}
