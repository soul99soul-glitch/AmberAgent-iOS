import Foundation
@testable import iosApp

// MARK: - Jev 测试共享支撑
//
// transport 存根的非 @Sendable 闭包由 @unchecked Sendable 类承载（仅测试用），
// 避免 @Sendable 捕获检查把用例写法绑死。锁经 jevSync 包装（Swift 6 禁止在
// async 函数体内直接 lock/unlock）。

/// 同步临界区包装（测试用）。
func jevSync<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// 线程安全计数器。
final class JevCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        jevSync(lock) {
            value += 1
            return value
        }
    }
    var current: Int {
        jevSync(lock) { value }
    }
}

/// Jev transport 存根：记录调用次数与请求体，handler 可自由捕获测试 self。
final class JevStubTransport: IOSJevTransport, @unchecked Sendable {
    let handler: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var _calls = 0
    private var _lastBody: Data?
    private var _cancelled = false

    init(handler: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    var calls: Int { jevSync(lock) { _calls } }
    var lastBody: Data? { jevSync(lock) { _lastBody } }
    var sawCancellation: Bool { jevSync(lock) { _cancelled } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        jevSync(lock) {
            _calls += 1
            if let body = request.httpBody { _lastBody = body }
        }
        return try await withTaskCancellationHandler {
            try await self.handler(request)
        } onCancel: {
            jevSync(self.lock) { self._cancelled = true }
        }
    }
}

/// 组装 HTTPURLResponse（在闭包内调用，避免捕获非 Sendable 响应对象）。
func jevResponse(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: IOSJevSettings.productionEndpoint,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    )!
}

/// Score 型响应体（官方契约：answers map + usage）。
func jevScorePayload(_ answers: [String: Double], confidence: Double? = nil) -> Data {
    var answerObjects: [String: [String: Any]] = [:]
    for (id, score) in answers {
        var object: [String: Any] = ["type": "score", "score": score]
        if let confidence { object["confidence"] = confidence }
        answerObjects[id] = object
    }
    let payload: [String: Any] = [
        "model": "jev-latest",
        "answers": answerObjects,
        "usage": ["input_tokens": 12, "output_tokens": 34],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

/// Noul + Choice 混合响应体。
func jevMixedPayload(noul: [String: Double], choice: [String: String]) -> Data {
    var answers: [String: [String: Any]] = [:]
    for (id, probability) in noul {
        answers[id] = ["type": "noul", "noul": probability]
    }
    for (id, option) in choice {
        answers[id] = ["type": "choice", "choice": option, "confidence": 0.7]
    }
    let payload: [String: Any] = [
        "model": "jev-latest",
        "answers": answers,
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}
