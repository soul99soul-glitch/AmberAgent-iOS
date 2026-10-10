import AmberPhoneControl
import Foundation
@preconcurrency import Shared

/// Foreground and background engines use the same run-scoped controller.
/// Authorization and launcher ownership stay outside the model's arguments.
@MainActor
final class IOSPhoneControlToolExecutor: IOSToolExecutor {
    private let runID: String
    private let controller: IOSPhoneControlController

    init(runID: String, controller: IOSPhoneControlController = .shared) {
        self.runID = runID
        self.controller = controller
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let request: Request
        do {
            request = try Self.request(name: name, arguments: arguments)
        } catch {
            return .failed(Self.json([
                "outcome": "not_sent", "retry_safe": true,
                "code": "invalid_arguments", "message": error.localizedDescription,
            ]))
        }

        switch request {
        case .status:
            // Status is useful after stop as well; it never starts a session.
            return .filled(controller.statusText(runID: runID))
        case .stop:
            guard controller.ownerRunID == runID else {
                return .denied(Self.json([
                    "outcome": "not_sent", "retry_safe": false,
                    "code": "run_not_authorized", "message": "该 run 已不拥有手机控制会话。",
                ]))
            }
            await controller.stop(runID: runID)
            return .filled(Self.json([
                "outcome": "stopped", "retry_safe": true,
                "message": "当前 run 已停止接受手机控制动作；已发送的动作不能撤销。",
            ]))
        case .observe(let maxNodes, let includeScreenshot):
            let runner: PhoneRunnerClient
            do {
                runner = try controller.runner(runID: runID)
            } catch {
                return .denied(Self.denial(error))
            }
            do {
                let observation = try await runner.observe(maxNodes: maxNodes)
                var parts: [UIMessagePart] = [UIMessagePart.Text(text: observation.compactText, metadata: nil)]
                if includeScreenshot {
                    parts.append(Self.imagePart(try await runner.screenshot()))
                }
                return .filledParts(parts)
            } catch {
                return Self.readFailure(error)
            }
        case .act(let action):
            let runner: PhoneRunnerClient
            do {
                runner = try controller.runner(runID: runID)
            } catch {
                return .denied(Self.denial(error))
            }
            return Self.actionOutcome(await runner.act(action))
        }
    }

    // Internal seams keep tests focused on argument and engine-result contracts.
    enum Request: Equatable {
        case status
        case observe(maxNodes: Int, includeScreenshot: Bool)
        case act(PhoneAction)
        case stop
    }

    static func request(name: String, arguments: String) throws -> Request {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidArguments("参数必须是 JSON 对象。")
        }
        switch name {
        case "phone_status", "phone_stop":
            guard object.isEmpty else { throw InvalidArguments("\(name) 不接受参数。") }
            return name == "phone_status" ? .status : .stop
        case "phone_observe":
            guard Set(object.keys).isSubset(of: ["max_nodes", "include_screenshot"]) else {
                throw InvalidArguments("phone_observe 只接受 max_nodes 和 include_screenshot。")
            }
            let input = try JSONDecoder().decode(ObserveArguments.self, from: data)
            let maximum = input.maxNodes ?? 500
            guard (1...500).contains(maximum) else {
                throw InvalidArguments("max_nodes 必须是 1 到 500 的整数。")
            }
            return .observe(maxNodes: maximum, includeScreenshot: input.includeScreenshot ?? false)
        case "phone_act":
            let input = try JSONDecoder().decode(ActionArguments.self, from: data)
            let keys: Set<String>
            let action: PhoneAction
            switch input.action {
            case "launch":
                keys = ["action", "bundle_id"]
                action = .launch(bundleID: try required(input.bundleID, "bundle_id"))
            case "tap":
                keys = ["action", "ref"]
                action = .tap(ref: try required(input.ref, "ref"))
            case "type":
                keys = ["action", "ref", "text"]
                action = .type(ref: try required(input.ref, "ref"), text: try required(input.text, "text"))
            case "swipe":
                keys = ["action", "ref", "direction"]
                guard let direction = input.direction.flatMap(PhoneSwipeDirection.init(rawValue:)) else {
                    throw InvalidArguments("direction 必须是 up、down、left 或 right。")
                }
                action = .swipe(ref: try required(input.ref, "ref"), direction: direction)
            default:
                throw InvalidArguments("action 必须是 launch、tap、type 或 swipe。")
            }
            guard Set(object.keys).isSubset(of: keys) else {
                throw InvalidArguments("\(input.action) 包含不适用的参数。")
            }
            return .act(action)
        default:
            throw InvalidArguments("未知的手机控制工具：\(name)。")
        }
    }

    static func imagePart(_ png: Data) -> UIMessagePart.Image {
        UIMessagePart.Image(url: "data:image/png;base64,\(png.base64EncodedString())", metadata: nil)
    }

    static func actionOutcome(_ result: PhoneActionResult) -> IOSAgentToolOutcome {
        switch result {
        case .completed:
            return .filled(json([
                "outcome": "completed", "retry_safe": false,
                "message": "控制 runner 已返回执行回执。请重新 phone_observe 验证业务效果，不要重放同一动作。",
            ]))
        case .unsent(let problem):
            let text = json(problemFields(problem, outcome: "not_sent", retrySafe: problem.kind != .previousOutcomeUnknown))
            return isDenied(problem) ? .denied(text) : .failed(text)
        case .unknown(let problem):
            let text = json(problemFields(problem, outcome: "unknown", retrySafe: false))
            return .outcomeUnknown([UIMessagePart.Text(text: text, metadata: nil)])
        }
    }

    private static func readFailure(_ error: Error) -> IOSAgentToolOutcome {
        if let problem = error as? PhoneControlProblem {
            let text = json(problemFields(problem, outcome: "not_sent", retrySafe: true))
            return isDenied(problem) ? .denied(text) : .failed(text)
        }
        return .failed(json([
            "outcome": "not_sent", "retry_safe": true,
            "code": "observation_failed", "message": error.localizedDescription,
        ]))
    }

    private static func isDenied(_ problem: PhoneControlProblem) -> Bool {
        problem.kind == .appOutOfScope || problem.kind == .stopped
            || problem.kind == .previousOutcomeUnknown
    }

    private static func problemFields(_ problem: PhoneControlProblem, outcome: String, retrySafe: Bool) -> [String: Any] {
        var fields: [String: Any] = [
            "outcome": outcome, "retry_safe": retrySafe,
            "code": problem.kind.rawValue, "message": problem.message,
            "dropped_before_execution": problem.wasDroppedBeforeExecution,
        ]
        if let status = problem.statusCode { fields["http_status"] = status }
        if let code = problem.runnerCode { fields["runner_code"] = code }
        return fields
    }

    private static func denial(_ error: Error) -> String {
        json([
            "outcome": "not_sent", "retry_safe": false,
            "code": "run_not_authorized", "message": error.localizedDescription,
        ])
    }

    private static func required(_ value: String?, _ name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw InvalidArguments("\(name) 是必填的非空字符串。")
        }
        return value
    }

    private static func json(_ value: [String: Any]) -> String {
        // All result fields are primitives, so serialization cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private struct ObserveArguments: Decodable {
        let maxNodes: Int?
        let includeScreenshot: Bool?
        enum CodingKeys: String, CodingKey {
            case maxNodes = "max_nodes", includeScreenshot = "include_screenshot"
        }
    }

    private struct ActionArguments: Decodable {
        let action: String
        let bundleID: String?
        let ref: String?
        let text: String?
        let direction: String?
        enum CodingKeys: String, CodingKey {
            case action, bundleID = "bundle_id", ref, text, direction
        }
    }

    private struct InvalidArguments: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
