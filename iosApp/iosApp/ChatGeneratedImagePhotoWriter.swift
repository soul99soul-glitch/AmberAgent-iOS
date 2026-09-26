import Foundation
import Photos

enum ChatGeneratedImagePhotoWriter {
    static func write(_ urlString: String) async throws {
        let resolvedStatus = await photoAuthorizationStatus()
        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw ChatGeneratedImagePhotoSaveError.notAuthorized
        }

        let source = try photoSaveSourceURL(from: urlString)
        defer {
            if source.removeAfterSave {
                try? FileManager.default.removeItem(at: source.url)
            }
        }

        try await saveImageFileToPhotoLibrary(source.url)
    }

    @MainActor
    private static func photoAuthorizationStatus() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .notDetermined else {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return status
    }

    private nonisolated static func photoSaveSourceURL(from urlString: String) throws -> PhotoSaveSource {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let resolvedURL = IOSImageGenerationRepository.resolvedImageURL(from: trimmed),
           resolvedURL.isFileURL {
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw ChatGeneratedImagePhotoSaveError.missingImageFile
            }
            return PhotoSaveSource(url: resolvedURL, removeAfterSave: false)
        }

        let data = try IOSImageGenerationRepository.imageData(from: trimmed)
        guard !data.isEmpty else {
            throw ChatGeneratedImagePhotoSaveError.invalidImage
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-generated-\(UUID().uuidString)")
            .appendingPathExtension(imageFileExtension(for: data))
        try data.write(to: temporaryURL, options: [.atomic])
        return PhotoSaveSource(url: temporaryURL, removeAfterSave: true)
    }

    private nonisolated static func saveImageFileToPhotoLibrary(_ fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ChatGeneratedImagePhotoSaveError.unknown)
                }
            }
        }
    }

    private nonisolated static func imageFileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0x47, 0x49, 0x46]) {
            return "gif"
        }
        if data.count >= 12,
           data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return "webp"
        }
        return "png"
    }
}

private struct PhotoSaveSource {
    let url: URL
    let removeAfterSave: Bool
}

private enum ChatGeneratedImagePhotoSaveError: LocalizedError {
    case notAuthorized
    case missingImageFile
    case invalidImage
    case unknown

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "没有相册写入权限。请在系统设置里允许 AmberAgent 添加照片。"
        case .missingImageFile:
            "当前图片文件已经不存在。重装 App 会删除 App 沙盒内的历史图片，需要重新生成后再保存。"
        case .invalidImage:
            "当前图片文件无法解码，可能已经被系统或重装流程删除。"
        case .unknown:
            "系统相册没有返回明确原因。"
        }
    }
}
