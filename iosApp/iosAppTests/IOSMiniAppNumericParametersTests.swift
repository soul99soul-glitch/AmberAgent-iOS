import XCTest
@testable import iosApp

@MainActor
final class IOSMiniAppNumericParametersTests: XCTestCase {
    func testJSONNumbersAreBoundedBeforeIntegerConversion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-numeric-parameters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = IOSMiniAppRepository(baseDirectory: directory, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "Numeric parameters", description: "Test",
            permissions: ["ai.generate", "host.context", "sensor"],
            html: "<!doctype html><html><body>Numbers</body></html>"
        ))
        defer {
            UserDefaults.standard.removeObject(forKey: "app.amber.ios.miniApp.aiBudget.\(app.id)")
        }
        for permission in app.permissions {
            try repository.setGrant(appId: app.id, permission: permission, decision: .allow)
        }
        var observedAI: Int?
        var observedContext: Int?
        var observedSensor: Int?
        let runtime = IOSMiniAppBridgeRuntime(
            appId: app.id,
            repository: repository,
            policy: IOSMiniAppBridgePolicy(aiEnabled: true, hostContextEnabled: true),
            aiGenerateHandler: { request in
                observedAI = request.maxOutputChars
                return .bool(true)
            },
            hostHandler: { request in
                guard case .getConversationContext(let context) = request else {
                    XCTFail("Unexpected host request")
                    return .bool(false)
                }
                observedContext = context.maxChars
                return .bool(true)
            },
            sensorSubscribeHandler: { _, _, intervalMs, _ in observedSensor = intervalMs },
            sensitiveConfirmationHandler: { _, _ in true }
        )
        defer { runtime.close() }
        let fixtures: [(String, Int, Int, Int)] = [
            ("1e100", 16_000, 8_000, 60_000),
            ("-1e100", 1, 200, 250),
            ("9223372036854775808", 16_000, 8_000, 60_000),
            ("345.9", 345, 345, 345),
            ("0", 1, 200, 250),
            ("-12.9", 1, 200, 250),
            ("16000", 16_000, 8_000, 16_000)
        ]
        for (number, expectedAI, expectedContext, expectedSensor) in fixtures {
            let ai = await runtime.dispatch(
                method: "ai.generate",
                params: try params(from: "{\"prompt\":\"test\",\"maxOutputChars\":\(number)}")
            )
            XCTAssertEqual(ai, .success(.bool(true)), number)
            XCTAssertEqual(observedAI, expectedAI, number)

            let context = await runtime.dispatch(
                method: "host.getConversationContext",
                params: try params(from: "{\"maxChars\":\(number)}")
            )
            XCTAssertEqual(context, .success(.bool(true)), number)
            XCTAssertEqual(observedContext, expectedContext, number)

            let sensor = await runtime.dispatch(
                method: "sensor.subscribe",
                params: try params(from: "{\"type\":\"gyroscope\",\"intervalMs\":\(number)}")
            )
            XCTAssertNil(sensor.errorMessage, number)
            XCTAssertEqual(observedSensor, expectedSensor, number)
        }
    }

    private func params(from json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
