import Foundation

enum ChatGeneratedImageURL {
    static let scheme = "amber-image-generation"
    private static let generatedImageDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("image-generation", isDirectory: true)

    static func resolvedImageURL(
        from raw: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case Self.scheme:
                return generatedImageDirectory.appendingPathComponent(url.lastPathComponent)
            case "file":
                return resolveFileURL(url, fileExists: fileExists)
            case "http", "https":
                return url
            default:
                return url
            }
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        return resolveFileURL(fileURL, fileExists: fileExists)
    }

    private static func resolveFileURL(_ url: URL, fileExists: (String) -> Bool) -> URL {
        // Skip synchronous disk stats unless the path looks like an old app
        // container's `/image-generation/` location that actually differs from
        // the current container directory.
        guard let repaired = repairedGeneratedImageURL(from: url),
              repaired.standardizedFileURL.path != url.standardizedFileURL.path else {
            return url
        }
        if fileExists(url.path) {
            return url
        }
        if fileExists(repaired.path) {
            return repaired
        }
        return url
    }

    private static func repairedGeneratedImageURL(from staleURL: URL) -> URL? {
        guard staleURL.path.contains("/image-generation/") else { return nil }
        let fileName = staleURL.lastPathComponent
        guard !fileName.isEmpty else { return nil }
        return generatedImageDirectory.appendingPathComponent(fileName, isDirectory: false)
    }
}
