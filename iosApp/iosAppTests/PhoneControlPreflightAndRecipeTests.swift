import XCTest
@testable import iosApp

@MainActor
final class PhoneControlPreflightAndRecipeTests: XCTestCase {
    func testPreflightIsPureZeroLeaseAndReportsExactBlockers() throws {
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName(IOSPhoneControlToolCatalog.preflightToolName, input: "{}"),
            .pure
        )
        XCTAssertFalse(IOSPhoneControlToolCatalog.isPhoneTool(name: IOSPhoneControlToolCatalog.preflightToolName))

        let suite = "PhonePreflightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = IOSPhoneControlController(defaults: defaults, credentials: IOSPhoneControlCredentials())
        controller.enabled = false

        let rawDisabled = IOSPhoneControlToolExecutor.preflightJSON(controller: controller)
        let disabledObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(rawDisabled.utf8)) as? [String: Any]
        )
        XCTAssertEqual(disabledObj["ok"] as? Bool, true)
        XCTAssertEqual(disabledObj["ready"] as? Bool, false)
        XCTAssertEqual(disabledObj["blocker"] as? String, "disabled")
        XCTAssertEqual(disabledObj["settings_deep_link"] as? String, "amber://settings/phone-control")
        XCTAssertNil(controller.ownerRunID)
        XCTAssertEqual(controller.phase, .idle)

        controller.enabled = true
        let rawEnabled = IOSPhoneControlToolExecutor.preflightJSON(controller: controller)
        let enabledObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(rawEnabled.utf8)) as? [String: Any]
        )
        XCTAssertEqual(enabledObj["enabled"] as? Bool, true)
        XCTAssertEqual(enabledObj["ready"] as? Bool, false)
        XCTAssertNotEqual(enabledObj["blocker"] as? String, "disabled")
        XCTAssertNil(controller.ownerRunID)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testPhoneRecipeStoreV2MigratesV1RedactsSensitiveEnforcesLRU5AndMarksReverify() throws {
        let suite = "PhoneRecipeV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // 1. Lossless v1 -> v2 migration
        defaults.set(
            ["com.apple.mobilenotes": ["goal": "打开备忘录", "steps": ["launch", "tap 新建"]]],
            forKey: PhoneRecipeStore.legacyKey
        )
        let migrated = PhoneRecipeStore.candidates(bundleID: "com.apple.mobilenotes", goal: "打开备忘录", defaults: defaults)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.steps, ["launch", "tap 新建"])
        XCTAssertNotNil(defaults.data(forKey: PhoneRecipeStore.key))

        // 2. Sensitive context opt-out
        PhoneRecipeStore.save(
            bundleID: "com.bank.app",
            goal: "输入银行卡支付密码",
            steps: ["tap 付款", "type 123456"],
            defaults: defaults
        )
        XCTAssertTrue(PhoneRecipeStore.candidates(bundleID: "com.bank.app", defaults: defaults).isEmpty)

        PhoneRecipeStore.save(
            bundleID: "com.example.shop",
            goal: "普通搜索",
            steps: ["tap search"],
            isSensitive: true,
            defaults: defaults
        )
        XCTAssertTrue(PhoneRecipeStore.candidates(bundleID: "com.example.shop", defaults: defaults).isEmpty)

        // 3. Credential redaction in stored steps
        PhoneRecipeStore.save(
            bundleID: "com.example.chat",
            goal: "配置连接",
            steps: ["type Bearer supersecret_token_abcdef123"],
            defaults: defaults
        )
        let chatRecipes = PhoneRecipeStore.candidates(bundleID: "com.example.chat", defaults: defaults)
        XCTAssertEqual(chatRecipes.count, 1)
        XCTAssertFalse(chatRecipes.first?.steps.first?.contains("supersecret_token_abcdef123") ?? true)

        // 4. Per-app LRU cap of 5 recipes
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 1...7 {
            PhoneRecipeStore.save(
                bundleID: "com.example.music",
                goal: "播放列表 \(index)",
                steps: ["tap 列表\(index)"],
                now: baseDate.addingTimeInterval(Double(index * 60)),
                defaults: defaults
            )
        }
        let musicRecipes = PhoneRecipeStore.candidates(
            bundleID: "com.example.music",
            limit: 10,
            defaults: defaults
        )
        XCTAssertEqual(musicRecipes.count, PhoneRecipeStore.maxRecipesPerApp)
        let goals = Set(musicRecipes.map(\.goal))
        XCTAssertFalse(goals.contains("播放列表 1"))
        XCTAssertFalse(goals.contains("播放列表 2"))
        XCTAssertTrue(goals.contains("播放列表 7"))

        // 5. Mark needsReverify drops priority below verified recipes
        PhoneRecipeStore.markNeedsReverify(bundleID: "com.example.music", goal: "播放列表 7", defaults: defaults)
        let afterFailure = PhoneRecipeStore.candidates(bundleID: "com.example.music", limit: 5, defaults: defaults)
        let flagged = afterFailure.first { $0.goal == "播放列表 7" }
        XCTAssertEqual(flagged?.needsReverify, true)
        XCTAssertEqual(afterFailure.first?.needsReverify, false)
    }
}
