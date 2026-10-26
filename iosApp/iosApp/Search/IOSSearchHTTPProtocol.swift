import Foundation

@MainActor
protocol IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data)
    func sendPublic(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (HTTPURLResponse, Data)
}

extension IOSSearchHTTPTransport {
    func sendPublic(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (HTTPURLResponse, Data) {
        let (response, data) = try await send(request)
        guard data.count <= maximumResponseBytes else {
            throw IOSSearchExecutorError.responseTooLarge(maximumResponseBytes)
        }
        return (response, data)
    }
}

