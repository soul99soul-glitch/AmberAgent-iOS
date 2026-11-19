import CryptoKit
import SwiftUI
import UIKit

enum ChatDataImageLoadState: Sendable {
    case loading
    case success(UIImage)
    case failure

    static func resolve(urlString: String) async -> ChatDataImageLoadState {
        await ChatDataImageLoader.shared.resolve(urlString: urlString)
    }
}

/// Decodes `data:image/...` URLs once off the main actor, keeps an in-memory
/// prepared bitmap cache, and coalesces concurrent callers at full source quality.
actor ChatDataImageLoader {
    static let shared = ChatDataImageLoader()

    private struct InFlightEntry {
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        let task: Task<Void, Never>
    }

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: InFlightEntry] = [:]
    private let onDecode: (@Sendable () -> Void)?

    init(
        costLimit: Int = 48 * 1024 * 1024,
        onDecode: (@Sendable () -> Void)? = nil
    ) {
        self.onDecode = onDecode
        cache.totalCostLimit = costLimit
    }

    func resolve(urlString: String) async -> ChatDataImageLoadState {
        guard !Task.isCancelled else { return .failure }
        let key = Self.cacheKey(for: urlString)
        if let cached = cache.object(forKey: key as NSString) {
            return .success(cached)
        }
        let waiterID = UUID()
        let image = await withTaskCancellationHandler {
            await awaitDecodedImage(key: key, urlString: urlString, waiterID: waiterID)
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
        guard !Task.isCancelled, let image else { return .failure }
        return .success(image)
    }

    private func awaitDecodedImage(key: String, urlString: String, waiterID: UUID) async -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if Task.isCancelled {
            return nil
        }
        return await withCheckedContinuation { continuation in
            var entry = inFlight[key] ?? InFlightEntry(
                task: Task { [weak self] in
                    let decoded = await self?.decodePreparedImage(urlString: urlString)
                    await self?.finishInFlight(key: key, image: decoded)
                }
            )
            entry.waiters[waiterID] = continuation
            inFlight[key] = entry
        }
    }

    private func cancelWaiter(key: String, waiterID: UUID) {
        guard var entry = inFlight[key],
              let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        inFlight[key] = entry
        continuation.resume(returning: nil)
    }

    private func finishInFlight(key: String, image: UIImage?) {
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.pixelCost(of: image))
        }
        guard let entry = inFlight.removeValue(forKey: key) else { return }
        for continuation in entry.waiters.values {
            continuation.resume(returning: image)
        }
    }

    private func decodePreparedImage(urlString: String) async -> UIImage? {
        onDecode?()
        return await Task.detached(priority: .userInitiated) {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
                  let rawImage = UIImage(data: data) else {
                return nil
            }
            return rawImage.preparingForDisplay() ?? rawImage
        }.value
    }

    private static func cacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return "data-image:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pixelCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let scale = image.scale
        return max(1, Int(image.size.width * scale * image.size.height * scale * 4))
    }
}


