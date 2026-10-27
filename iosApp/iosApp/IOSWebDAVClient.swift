import Foundation

struct IOSWebDAVConfig: Codable, Equatable {
    var baseURL: String = ""
    var path: String = "AmberAgent"
    var username: String = ""
    var password: String = ""

    var isConfigured: Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    func validateDirectoryPath() throws {
        guard !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw IOSSyncBackupError.providerNotConfigured("WebDAV 目录不能包含 .、..、反斜杠或控制字符。")
        }
    }
}

protocol IOSWebDAVTransport: Sendable {
    func send(_ request: URLRequest, body: Data?) async throws -> (HTTPURLResponse, Data)
}

struct IOSURLSessionWebDAVTransport: IOSWebDAVTransport {
    func send(_ request: URLRequest, body: Data?) async throws -> (HTTPURLResponse, Data) {
        let result: (Data, URLResponse)
        if let body {
            result = try await URLSession.shared.upload(for: request, from: body)
        } else {
            result = try await URLSession.shared.data(for: request)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw IOSSyncBackupError.invalidArchive("WebDAV 响应不是 HTTP")
        }
        return (response, result.0)
    }
}

struct IOSWebDAVClient: Sendable {
    let config: IOSWebDAVConfig
    let transport: any IOSWebDAVTransport

    init(config: IOSWebDAVConfig, transport: any IOSWebDAVTransport = IOSURLSessionWebDAVTransport()) {
        self.config = config
        self.transport = transport
    }

    func testConnection() async throws { _ = try await propfind(depth: 0) }

    func listResources() async throws -> [IOSWebDAVResource] {
        try await ensureCollectionExists()
        return try await propfind(depth: 1)
    }

    /// Returns the server's revision of the uploaded file, the same value a later listing reports.
    func upload(data: Data, fileName: String, mimeType: String, createOnly: Bool = false) async throws -> String {
        try await ensureCollectionExists()
        var headers = ["Content-Type": mimeType, "Content-Length": "\(data.count)"]
        if createOnly { headers["If-None-Match"] = "*" }
        let request = try makeRequest(method: "PUT", fileName: fileName, headers: headers)
        let (response, _) = try await transport.send(request, body: data)
        try validate(response: response, accepted: 200, 201, 204)
        let etag = response.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        if !etag.isEmpty { return etag }
        // PUT may omit ETag. Read the server's revision so a later listing
        // compares the same value, rather than treating our upload as a conflict.
        let resources = try await propfind(depth: 0, fileName: fileName)
        guard let resource = resources.first(where: { !$0.isCollection }), !resource.remoteRevision.isEmpty else {
            throw IOSSyncBackupError.remoteProviderUnavailable("WebDAV 上传已完成，但无法读取远端文件版本")
        }
        return resource.remoteRevision
    }

    func download(fileName: String) async throws -> Data {
        let request = try makeRequest(method: "GET", fileName: fileName)
        let (response, data) = try await transport.send(request, body: nil)
        try validate(response: response, accepted: 200)
        return data
    }

    func delete(fileName: String) async throws {
        let request = try makeRequest(method: "DELETE", fileName: fileName)
        let (response, _) = try await transport.send(request, body: nil)
        try validate(response: response, accepted: 200, 202, 204, 404)
    }

    /// Creates each missing parent, then the final collection (MKCOL doesn't create intermediates).
    private func ensureCollectionExists() async throws {
        guard !config.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try config.validateDirectoryPath()
        let components = config.path.split(separator: "/")
        guard !components.isEmpty else { return }
        guard var url = URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IOSSyncBackupError.providerNotConfigured("WebDAV URL 未配置")
        }
        for component in components {
            url.appendPathComponent(String(component), isDirectory: true)
            let request = try makeRequest(method: "MKCOL", url: url)
            let (response, _) = try await transport.send(request, body: nil)
            try validate(response: response, accepted: 200, 201, 204, 405)
        }
    }

    private func propfind(depth: Int, fileName: String? = nil) async throws -> [IOSWebDAVResource] {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getcontenttype/>
            <D:getlastmodified/>
            <D:getetag/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)
        let request = try makeRequest(method: "PROPFIND", fileName: fileName, headers: [
            "Content-Type": "application/xml; charset=utf-8",
            "Depth": "\(depth)",
        ])
        let (response, data) = try await transport.send(request, body: body)
        try validate(response: response, accepted: 200, 207)
        return try IOSWebDAVPropfindParser.parse(data: data)
    }

    func makeRequest(method: String, fileName: String? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        try config.validateDirectoryPath()
        if let fileName {
            guard !fileName.isEmpty, fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                  !fileName.contains("\\") else {
                throw IOSSyncBackupError.invalidArchive("Invalid snapshot file name: \(fileName)")
            }
        }
        guard let url = buildURL(fileName: fileName) else {
            throw IOSSyncBackupError.providerNotConfigured("WebDAV URL 未配置")
        }
        return try makeRequest(method: method, url: url, headers: headers)
    }

    private func makeRequest(method: String, url: URL, headers: [String: String] = [:]) throws -> URLRequest {
        if (!config.username.isEmpty || !config.password.isEmpty),
           url.scheme?.lowercased() != "https" {
            throw IOSSyncBackupError.providerNotConfigured("WebDAV Basic 认证只允许使用 HTTPS")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !config.username.isEmpty || !config.password.isEmpty {
            let raw = "\(config.username):\(config.password)"
            let encoded = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private func buildURL(fileName: String?) -> URL? {
        guard var url = URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let pathParts = config.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        for part in pathParts {
            url.appendPathComponent(part, isDirectory: true)
        }
        if let fileName {
            url.appendPathComponent(fileName, isDirectory: false)
        }
        return url
    }

    private func validate(response: HTTPURLResponse, accepted codes: Int...) throws {
        guard codes.contains(response.statusCode) || (200...299).contains(response.statusCode) else {
            throw IOSSyncBackupError.remoteProviderUnavailable("WebDAV 请求失败：HTTP \(response.statusCode)")
        }
    }
}

struct IOSWebDAVResource: Equatable, Sendable {
    let href: String
    let displayName: String
    let sizeBytes: Int64
    let modifiedAt: Int64
    let etag: String
    let isCollection: Bool

    var remoteRevision: String { etag.isEmpty ? href : etag }

    var remoteFileName: String {
        guard let path = URLComponents(string: href)?.percentEncodedPath,
              let component = path.split(separator: "/").last,
              let decoded = String(component).removingPercentEncoding,
              !decoded.contains("/"), !decoded.contains("\\") else { return "" }
        return decoded
    }

    var fileName: String {
        if !displayName.isEmpty {
            return displayName
        }
        return href.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init) ?? href
    }
}

private final class IOSWebDAVPropfindParser: NSObject, XMLParserDelegate {
    private var resources: [IOSWebDAVResource] = []
    private var currentHref = ""
    private var currentDisplayName = ""
    private var currentSize: Int64 = 0
    private var currentModifiedAt: Int64 = 0
    private var currentEtag = ""
    private var currentIsCollection = false
    private var currentText = ""
    private var inResponse = false

    static func parse(data: Data) throws -> [IOSWebDAVResource] {
        let delegate = IOSWebDAVPropfindParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw IOSSyncBackupError.remoteProviderUnavailable("WebDAV 返回了无法解析的资源列表。") }
        return delegate.resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.localXMLName
        currentText = ""
        if name == "response" {
            inResponse = true
            currentHref = ""
            currentDisplayName = ""
            currentSize = 0
            currentModifiedAt = 0
            currentEtag = ""
            currentIsCollection = false
        } else if name == "collection", inResponse {
            currentIsCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.localXMLName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inResponse {
            switch name {
            case "href":
                currentHref = text
            case "displayname":
                currentDisplayName = text
            case "getcontentlength":
                currentSize = Int64(text) ?? 0
            case "getlastmodified":
                currentModifiedAt = Self.parseWebDAVDate(text)
            case "getetag":
                currentEtag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "response":
                resources.append(IOSWebDAVResource(
                    href: currentHref,
                    displayName: currentDisplayName,
                    sizeBytes: currentSize,
                    modifiedAt: currentModifiedAt,
                    etag: currentEtag,
                    isCollection: currentIsCollection
                ))
                inResponse = false
            default:
                break
            }
        }
        currentText = ""
    }

    private static func parseWebDAVDate(_ value: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return 0
    }
}

private extension String {
    var localXMLName: String { split(separator: ":").last.map(String.init) ?? self }
}
