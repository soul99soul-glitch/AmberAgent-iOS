import XCTest
@testable import iosApp

@MainActor
final class IOSShortcutAuthoringTests: XCTestCase {
    func testRegistryUsesRealAmberIntentTypeNamesAndParameterNames() {
        let types: [Any.Type] = [
            IOSAskAmberIntent.self, IOSDailyBriefIntent.self, IOSNewConversationIntent.self,
            IOSResumeLatestConversationIntent.self, IOSOpenActiveTaskIntent.self,
            IOSContinueConversationIntent.self, IOSRunSavedActionIntent.self,
            IOSRunDueWakeTasksIntent.self, IOSSignalWakeEventIntent.self, IOSOpenAndRunDueWakeTasksIntent.self,
            IOSScheduleWakeTaskIntent.self, IOSScheduleEventWakeTaskIntent.self, IOSListWakeTasksIntent.self,
            IOSCancelWakeTaskIntent.self, IOSRunWakeTaskIntent.self, IOSReadLatestAnswerIntent.self,
            IOSWaitForWakeTaskIntent.self, IOSReadWakeTaskResultIntent.self,
            IOSSendConversationMessageIntent.self, IOSRunSavedActionInBackgroundIntent.self,
        ]
        XCTAssertEqual(Set(IOSShortcutAuthoringRegistry.actions.map(\.id)), Set(types.map { String(describing: $0) }))
        let schedule = IOSShortcutAuthoringRegistry.actions.first { $0.id == "IOSScheduleWakeTaskIntent" }
        XCTAssertEqual(schedule?.parameters.filter(\.required).map(\.name), ["taskTitle", "prompt", "date"])
        XCTAssertEqual(schedule?.parameters.map(\.name), ["taskTitle", "prompt", "date", "conversation", "requiresForeground"])
        let event = IOSShortcutAuthoringRegistry.actions.first { $0.id == "IOSSignalWakeEventIntent" }
        XCTAssertEqual(event?.parameters.map(\.name), ["event", "content"])
        // These key paths also fail compilation if an intent parameter is renamed.
        _ = \IOSSignalWakeEventIntent.event
        _ = \IOSSignalWakeEventIntent.content
        _ = \IOSScheduleWakeTaskIntent.taskTitle
        _ = \IOSScheduleWakeTaskIntent.prompt
        _ = \IOSScheduleWakeTaskIntent.date
        _ = \IOSScheduleWakeTaskIntent.conversation
        _ = \IOSScheduleWakeTaskIntent.requiresForeground
        _ = \IOSWaitForWakeTaskIntent.task
        _ = \IOSWaitForWakeTaskIntent.timeoutSeconds
        _ = \IOSReadWakeTaskResultIntent.task
    }

    func testComposeDoesNotClaimThatTheShortcutWasInstalledOrVerified() async throws {
        let result = try await compose(actions: [["action": "IOSRunDueWakeTasksIntent", "parameters": [:]]])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "plan_ready")
        XCTAssertEqual(result["installed"] as? Bool, false)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(result["execution_required"] as? Bool, true)
        let steps = try XCTUnwrap(result["phone_ui_steps"] as? [[String: String]])
        XCTAssertEqual(steps.first?["tool"], "phone_apps")
        XCTAssertEqual(steps[1]["tool"], "phone_add_app")
        XCTAssertTrue(steps.contains { $0["tool"] == "phone_observe" })
        XCTAssertEqual(steps.last?["tool"], "phone_return_to_amber")
        XCTAssertTrue((result["continuation"] as? String)?.contains("继续执行手机 UI") == true)
    }

    func testMissingRequiredAndUnknownParametersAreRejected() async throws {
        let missing = try await compose(actions: [["action": "IOSSignalWakeEventIntent", "parameters": [:]]])
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertTrue((missing["reason"] as? String)?.contains("event") == true)
        let unknown = try await compose(actions: [[
            "action": "IOSRunDueWakeTasksIntent", "parameters": ["runEverything": true],
        ]])
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertTrue((unknown["reason"] as? String)?.contains("runEverything") == true)
    }

    func testUnknownActionsAndTopLevelKeysAreRejected() async throws {
        let unknown = try await compose(actions: [["action": "InstallShortcutWithoutConfirmation", "parameters": [:]]])
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertNotNil(unknown["supported_actions"])
        let root = try await execute([
            "title": "任务", "goal": "测试", "install": true,
            "actions": [["action": "IOSRunDueWakeTasksIntent", "parameters": [:]]],
        ])
        XCTAssertEqual(root["ok"] as? Bool, false)
        XCTAssertTrue((root["reason"] as? String)?.contains("install") == true)
    }

    func testDatesBooleansAndShortcutVariableBindingsAreValidated() async throws {
        let base: [String: Any] = ["taskTitle": "检查回复", "prompt": "检查已授权的回复", "date": "2026-10-19T16:00:00+08:00"]
        var invalid = base
        invalid["requiresForeground"] = "true"
        let invalidResult = try await compose(actions: [["action": "IOSScheduleWakeTaskIntent", "parameters": invalid]])
        XCTAssertEqual(invalidResult["ok"] as? Bool, false)
        var variables = base
        variables["date"] = "{{下次检查时间}}"
        variables["requiresForeground"] = "{{是否需要界面}}"
        variables["conversation"] = "{{目标对话}}"
        let result = try await compose(actions: [["action": "IOSScheduleWakeTaskIntent", "parameters": variables]])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let workflow = try XCTUnwrap(result["workflow"] as? [String: Any])
        let actions = try XCTUnwrap(workflow["actions"] as? [[String: Any]])
        let parameters = try XCTUnwrap(actions.first?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["date"] as? String, "{{下次检查时间}}")
        XCTAssertTrue((result["variable_binding"] as? String)?.contains("不能把占位符文本直接填进最终动作") == true)
        var malformedDate = base
        malformedDate["date"] = "tomorrow"
        let malformedResult = try await compose(actions: [["action": "IOSScheduleWakeTaskIntent", "parameters": malformedDate]])
        XCTAssertEqual(malformedResult["ok"] as? Bool, false)
    }

    func testURLsRoundTripUnicodeAndQueryCharactersWithoutImportPayload() async throws {
        let title = "Amber：检查 & 回复？#1/原稿 + 修订"
        let result = try await compose(title: title, actions: [["action": "IOSReadLatestAnswerIntent", "parameters": [:]]])
        let urls = try XCTUnwrap(result["urls"] as? [String: String])
        XCTAssertEqual(urls["create"], "shortcuts://create-shortcut")
        for key in ["open", "run"] {
            let components = try XCTUnwrap(URLComponents(string: try XCTUnwrap(urls[key])))
            XCTAssertEqual(components.scheme, "shortcuts")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "name", value: title)])
            XCTAssertNil(components.fragment)
        }
    }

    func testAutomationRequiresConfigurationAndAnActualTriggerReceipt() async throws {
        let result = try await compose(actions: [["action": "IOSRunDueWakeTasksIntent", "parameters": [:]]], trigger: "每天上午 9 点")
        let steps = try XCTUnwrap(result["phone_ui_steps"] as? [[String: String]])
        XCTAssertTrue(steps.contains { $0["instruction"]?.contains("个人自动化界面") == true })
        let acceptance = try XCTUnwrap(result["acceptance"] as? [String])
        XCTAssertTrue(acceptance.contains { $0.contains("只手动运行快捷指令不能证明自动化触发成功") })
        XCTAssertEqual(result["verified"] as? Bool, false)
    }

    func testWaitActionIntegerBoundsRejectBooleansFractionsAndLongWaits() async throws {
        for timeout: Any in [true, 0, 26, 1.5, "20"] {
            let result = try await compose(actions: [[
                "action": "IOSWaitForWakeTaskIntent", "parameters": ["task": "{{刚安排的任务}}", "timeoutSeconds": timeout],
            ]])
            XCTAssertEqual(result["ok"] as? Bool, false)
        }
        for timeout: Any in [1, 25, "{{等待秒数}}"] {
            let result = try await compose(actions: [[
                "action": "IOSWaitForWakeTaskIntent", "parameters": ["task": "{{刚安排的任务}}", "timeoutSeconds": timeout],
            ]])
            XCTAssertEqual(result["ok"] as? Bool, true)
        }
    }

    func testCatalogIsLocalAndNeedsNoApproval() throws {
        let declaration = try XCTUnwrap(IOSShortcutAuthoringToolCatalog.declarations.first)
        XCTAssertEqual(declaration.name, "shortcut_compose")
        XCTAssertFalse(declaration.needsApproval)
        XCTAssertFalse(declaration.mandatoryApproval)
    }

    private func compose(title: String = "Amber 自动化", actions: [[String: Any]], trigger: String? = nil) async throws -> [String: Any] {
        var input: [String: Any] = ["title": title, "goal": "完成已授权的工作", "actions": actions]
        if let trigger { input["trigger"] = trigger }
        return try await execute(input)
    }

    private func execute(_ object: [String: Any]) async throws -> [String: Any] {
        let input = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let output = await IOSShortcutAuthoringToolExecutor.execute(input: input)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
