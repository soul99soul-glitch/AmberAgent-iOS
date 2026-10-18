import Foundation
import CryptoKit
@preconcurrency import Shared

/// Carries asynchronous attachment identities and the bounded OCR cache.
/// UI presentation stays on the per-conversation observable run state.
@MainActor
final class ChatAttachmentOperationOwner {
    var selectedFileRequestId: UUID?
    var visionTask: Task<Void, Never>?
    var visionRequestId: UUID?
    var visionConversationId: KotlinUuid?

    private var visionRecognitionTexts: [String: String] = [:]
    private var visionRecognitionTextKeys: [String] = []
    private static let maxVisionRecognitionCacheEntries = 16

    func cachedVisionRecognitionText(for dataUrl: String) -> String? {
        let key = Self.visionRecognitionCacheKey(for: dataUrl)
        guard let text = visionRecognitionTexts[key] else { return nil }
        visionRecognitionTextKeys.removeAll { $0 == key }
        visionRecognitionTextKeys.append(key)
        return text
    }

    func cacheVisionRecognitionTexts(_ texts: [String: String]) {
        for (dataUrl, value) in texts {
            let key = Self.visionRecognitionCacheKey(for: dataUrl)
            visionRecognitionTexts[key] = value
            visionRecognitionTextKeys.removeAll { $0 == key }
            visionRecognitionTextKeys.append(key)
        }
        while visionRecognitionTextKeys.count > Self.maxVisionRecognitionCacheEntries {
            let evicted = visionRecognitionTextKeys.removeFirst()
            visionRecognitionTexts.removeValue(forKey: evicted)
        }
    }

    static func visionRecognitionCacheKey(for dataUrl: String) -> String {
        let digest = SHA256.hash(data: Data(dataUrl.utf8))
        let prefix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "vision:\(prefix)"
    }
}
