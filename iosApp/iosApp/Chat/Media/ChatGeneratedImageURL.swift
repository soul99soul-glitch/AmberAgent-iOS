import Foundation

enum ChatGeneratedImageURL {
    static let scheme = "amber-image-generation"

    static func resolvedImageURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case Self.scheme:
                return generatedImageDirectoryURL().appendingPathComponent(url.lastPathComponent)
            case "file":
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
                if let repaired = repairedGeneratedImageURL(from: url),
                   FileManager.default.fileExists(atPath: repaired.path) {
                    return repaired
                }
                return url
            case "http", "https":
                return url
            default:
                return url
            }
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        if let repaired = repairedGeneratedImageURL(from: fileURL),
           FileManager.default.fileExists(atPath: repaired.path) {
            return repaired
        }
        return fileURL
    }

    private static func generatedImageDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("image-generation", isDirectory: true)
    }

    private static func repairedGeneratedImageURL(from staleURL: URL) -> URL? {
        guard staleURL.path.contains("/image-generation/") else { return nil }
        let fileName = staleURL.lastPathComponent
        guard !fileName.isEmpty else { return nil }
        return generatedImageDirectoryURL().appendingPathComponent(fileName, isDirectory: false)
    }
}
