import CryptoKit
import Foundation

enum RunnerSigning {
    static func validToken(_ token: String) -> Bool {
        (32...128).contains(token.utf8.count)
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func authorization(token: String, method: String, target: String, body: Data,
                              timestamp: Int64, nonce: String) -> String {
        let digest = hex(SHA256.hash(data: body))
        let message = "ipu-runner-v1\n\(method.uppercased())\n\(target)\n\(timestamp)\n\(nonce)\n\(digest)"
        // The protocol uses the UTF-8 hex token as key bytes, not decoded hex bytes.
        let key = SymmetricKey(data: Data(token.utf8))
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
        return "IPU-HMAC-SHA256 ts=\(timestamp), nonce=\(nonce), sig=\(signature)"
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Refusing redirects keeps requests on the configured loopback endpoint.
private final class RunnerSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RunnerHTTP: Sendable {
    let token: String
    let port: UInt16
    let session: URLSession

    init(token: String, port: UInt16, configuration: URLSessionConfiguration?) {
        self.token = token
        self.port = port
        let config = configuration ?? .ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 35
        self.session = URLSession(configuration: config, delegate: RunnerSessionDelegate(), delegateQueue: nil)
    }

    func request(method: String = "GET", path: String, query: [String: String] = [:],
                 body: JSONValue? = nil) async throws -> RunnerResponse {
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw PhoneControlProblem(.invalidConfiguration, "Invalid runner request URL.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try body.map { try encoder.encode($0) } ?? Data()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = method == "POST" ? data : nil
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let target = components.percentEncodedPath
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authorization = RunnerSigning.authorization(
            token: token, method: method, target: target, body: data,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not return HTTP.")
        }
        let dropped = response.value(forHTTPHeaderField: "X-IPU-Dropped") == "1"
        let envelope = try? JSONDecoder().decode(JSONValue.self, from: responseData)
        if let value = envelope?["value"], let code = value["error"]?.string {
            throw PhoneControlProblem(.runner, value["message"]?.string ?? code,
                                      statusCode: response.statusCode, runnerCode: code,
                                      wasDroppedBeforeExecution: dropped)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PhoneControlProblem(.runner, "Runner returned HTTP \(response.statusCode).",
                                      statusCode: response.statusCode, wasDroppedBeforeExecution: dropped)
        }
        guard let value = envelope?["value"] else {
            throw PhoneControlProblem(.malformedResponse, "Runner response is missing a WebDriver value.",
                                      statusCode: response.statusCode)
        }
        return RunnerResponse(value: value, response: response)
    }
}

struct RunnerResponse: Sendable {
    let value: JSONValue
    let response: HTTPURLResponse
    func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
}

indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value) where value == "1" || value == "true": true
        case .string(let value) where value == "0" || value == "false": false
        default: nil
        }
    }
}
