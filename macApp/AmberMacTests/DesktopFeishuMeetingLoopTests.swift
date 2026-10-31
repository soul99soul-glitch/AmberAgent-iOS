import XCTest
@testable import AmberMac

/// M3.5: the meeting-closeout loop runs the same two Feishu writes after one review. A repeated run must not post
/// a second document or card into the group, and it has to say so instead of pretending it worked again.
@MainActor final class DesktopFeishuIdempotencyTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var transport: RecordingTransport!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-feishu-idem-\(UUID().uuidString)", isDirectory: true)
        suiteName = "amber.feishu.idem.\(UUID().uuidString)"
        transport = RecordingTransport()
    }

    override func tearDown() async throws {
        if let suiteName { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func store(configured: Bool = true) throws -> DesktopPluginStore {
        let store = DesktopPluginStore(directory: directory, defaults: UserDefaults(suiteName: suiteName)!,
            credentials: DesktopMemoryCredentials(), httpTransport: transport,
            calendarService: FakeCalendarService())
        if configured {
            try store.saveSettings(pluginID: "feishu_calendar", values: [
                "app_id": "cli_test", "app_secret": "secret_test", "default_receive_id": "oc_team"
            ])
        }
        return store
    }

    private func call(_ store: DesktopPluginStore, _ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let output = try await store.executeTool(qualifiedName: "plugin__feishu_calendar__\(tool)",
            argumentsJSON: try DesktopAppleScheduleTools.json(arguments))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    func testRepeatedDocumentWriteWithSameKeyDoesNotCreateASecondDocument() async throws {
        let store = try store()
        let first = try await call(store, "bot_create_doc", [
            "title": "10-31 产品周会纪要", "content": "结论一", "idempotency_key": "meeting:2026-10-31:product"
        ])
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertNil(first["replayed"])
        let documentID = try XCTUnwrap(first["document_id"] as? String)
        let createsAfterFirst = transport.writeCount(path: "/open-apis/docx/v1/documents")
        XCTAssertEqual(createsAfterFirst, 1)

        let replay = try await call(store, "bot_create_doc", [
            "title": "10-31 产品周会纪要", "content": "结论一", "idempotency_key": "meeting:2026-10-31:product"
        ])
        XCTAssertEqual(replay["document_id"] as? String, documentID)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1, "第二次不应再写入飞书")
        XCTAssertTrue((replay["note"] as? String)?.contains("没有再次") == true)
    }

    func testRepeatedCardSendWithSameKeyDoesNotPostTwice() async throws {
        let store = try store()
        try store.saveSettings(pluginID: "feishu_calendar", values: [
            "app_id": "cli_test", "app_secret": "secret_test", "default_receive_id": "oc_team",
            "bot_webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/hook_1"
        ])
        let first = try await call(store, "bot_send_message", [
            "title": "会后回执", "content": "纪要与待办已就绪", "msg_type": "text",
            "idempotency_key": "meeting:2026-10-31:receipt"
        ])
        XCTAssertEqual(first["ok"] as? Bool, true)
        let sends = transport.writeCount(path: "/bot/v2/hook/hook_1")
        XCTAssertEqual(sends, 1)

        let replay = try await call(store, "bot_send_message", [
            "title": "会后回执", "content": "纪要与待办已就绪", "msg_type": "text",
            "idempotency_key": "meeting:2026-10-31:receipt"
        ])
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(transport.writeCount(path: "/bot/v2/hook/hook_1"), 1, "同一幂等键不能重复发卡片")
    }

    func testDifferentKeysStillWriteSeparately() async throws {
        let store = try store()
        _ = try await call(store, "bot_create_doc", ["title": "A", "content": "a", "idempotency_key": "meeting:1"])
        _ = try await call(store, "bot_create_doc", ["title": "B", "content": "b", "idempotency_key": "meeting:2"])
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 2)
    }

    func testCallsWithoutAKeyKeepTheirOldBehaviour() async throws {
        let store = try store()
        _ = try await call(store, "bot_create_doc", ["title": "A", "content": "a"])
        let second = try await call(store, "bot_create_doc", ["title": "A", "content": "a"])
        XCTAssertNil(second["replayed"])
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 2, "没有键就按原样执行")
    }

    /// The key survives a relaunch: the replay check must read storage, not an in-memory cache.
    func testKeySurvivesStoreReload() async throws {
        let first = try await store()
        _ = try await call(first, "bot_create_doc", ["title": "T", "content": "c", "idempotency_key": "meeting:persist"])
        let restored = try store()
        let replay = try await call(restored, "bot_create_doc", ["title": "T", "content": "c", "idempotency_key": "meeting:persist"])
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1)
    }

    func testStorageDropsTheOldestKeysPastTheCap() {
        var storage: [String: String] = [:]
        for index in 0..<(DesktopFeishuIdempotency.limit + 20) {
            DesktopFeishuIdempotency.write(.init(key: "k\(index)", result: "{}", target: "t",
                recordedAt: String(format: "2026-10-%03d 10:00", index)), into: &storage)
        }
        let kept = storage.keys.filter { $0.hasPrefix(DesktopFeishuIdempotency.storagePrefix) }
        XCTAssertEqual(kept.count, DesktopFeishuIdempotency.limit)
        XCTAssertNil(storage["idem:k0"], "最早的键应被裁掉")
        XCTAssertNotNil(storage["idem:k\(DesktopFeishuIdempotency.limit + 19)"])
    }

    func testOversizedOrBlankKeysAreIgnored() {
        XCTAssertNil(DesktopFeishuIdempotency.normalize("   "))
        XCTAssertNil(DesktopFeishuIdempotency.normalize(nil))
        XCTAssertNil(DesktopFeishuIdempotency.normalize(String(repeating: "x", count: 129)))
        XCTAssertEqual(DesktopFeishuIdempotency.normalize("  meeting:1  "), "meeting:1")
    }

    /// M3.5: one call closes out a meeting. Re-running it after review must not create a second document
    /// or post a second receipt, and it must report what was replayed.
    func testMeetingCloseoutIsIdempotentAcrossReruns() async throws {
        let store = try store()
        let arguments: [String: Any] = [
            "title": "10-31 产品周会", "minutes": "## 结论\n1. 上线时间不变",
            "idempotency_key": "meeting:2026-10-31:product"
        ]
        let first = try await call(store, "meeting_closeout", arguments)
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(first["replayed"] as? Bool, false)
        let document = try XCTUnwrap(first["document"] as? [String: Any])
        XCTAssertEqual(document["document_id"] as? String, "doxcn_test")
        XCTAssertEqual(document["url"] as? String, "https://feishu.cn/docx/doxcn_test")
        let receipt = try XCTUnwrap(first["receipt"] as? [String: Any])
        XCTAssertNotNil(receipt["message_id"])
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1)

        let replay = try await call(store, "meeting_closeout", arguments)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(replay["document_replayed"] as? Bool, true)
        XCTAssertEqual(replay["receipt_replayed"] as? Bool, true)
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1, "不能建第二份纪要")
        XCTAssertEqual(transport.writeCount(path: "/im/v1/messages"), 1, "不能发第二条回执")
    }

    func testMeetingCloseoutDefaultsItsKeyToDayReceiveIDTitleAndMinutesDigest() async throws {
        let store = try store()
        let arguments: [String: Any] = ["title": "无键会议", "minutes": "纪要版本一"]
        let first = try await call(store, "meeting_closeout", arguments)
        let firstKey = try XCTUnwrap(first["idempotency_key"] as? String)
        XCTAssertTrue(firstKey.contains(":oc_team:无键会议:"), firstKey)
        let second = try await call(store, "meeting_closeout", arguments)
        XCTAssertEqual(second["replayed"] as? Bool, true, "同日同群同标题同纪要重复调用应命中幂等缓存")
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1)

        // Different minutes content or different receive_id on the same day must not hit the old cache.
        let revised = try await call(store, "meeting_closeout", ["title": "无键会议", "minutes": "纪要版本二"])
        XCTAssertEqual(revised["replayed"] as? Bool, false)
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 2)
    }

    func testLocalDemoModeWritesDoNotBlockSubsequentConfiguredRemoteWrites() async throws {
        let unconfigured = try store(configured: false)
        let localResult = try await call(unconfigured, "meeting_closeout", [
            "title": "产品周会", "minutes": "演示模式纪要", "idempotency_key": "meeting:demo-to-remote"
        ])
        let localDoc = try XCTUnwrap(localResult["document"] as? [String: Any])
        XCTAssertEqual(localDoc["channel"] as? String, "local")
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 0)

        // Now the user configures real Feishu credentials and runs the same meeting closeout.
        try unconfigured.saveSettings(pluginID: "feishu_calendar", values: [
            "app_id": "cli_test", "app_secret": "secret_test", "default_receive_id": "oc_team"
        ])
        let remoteResult = try await call(unconfigured, "meeting_closeout", [
            "title": "产品周会", "minutes": "演示模式纪要", "idempotency_key": "meeting:demo-to-remote"
        ])
        XCTAssertEqual(remoteResult["replayed"] as? Bool, false, "演示模式的本地记录不能阻塞配置凭据后的真实写入")
        let remoteDoc = try XCTUnwrap(remoteResult["document"] as? [String: Any])
        XCTAssertEqual(remoteDoc["channel"] as? String, "openapi")
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1)
        XCTAssertEqual(transport.writeCount(path: "/im/v1/messages"), 1)
    }

    func testConcurrentCallsWithSameIdempotencyKeySerializeAndWriteOnlyOnce() async throws {
        let store = try store()
        let argsJSON = try DesktopAppleScheduleTools.json([
            "title": "并发测试会议", "minutes": "只写一次", "idempotency_key": "meeting:concurrent-1"
        ])
        async let firstRaw = store.executeTool(
            qualifiedName: "plugin__feishu_calendar__meeting_closeout", argumentsJSON: argsJSON)
        async let secondRaw = store.executeTool(
            qualifiedName: "plugin__feishu_calendar__meeting_closeout", argumentsJSON: argsJSON)
        let (out1, out2) = try await (firstRaw, secondRaw)
        let obj1 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out1.utf8)) as? [String: Any])
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out2.utf8)) as? [String: Any])
        let replayedFlags = [obj1["replayed"] as? Bool ?? false, obj2["replayed"] as? Bool ?? false]
        XCTAssertEqual(replayedFlags.filter { $0 }.count, 1, "并发调用中第二次应等待第一次落盘并直接重放")
        XCTAssertEqual(transport.writeCount(path: "/open-apis/docx/v1/documents"), 1)
        XCTAssertEqual(transport.writeCount(path: "/im/v1/messages"), 1)
    }

    func testMeetingCloseoutCanSkipTheReceipt() async throws {
        let store = try store()
        let result = try await call(store, "meeting_closeout",
            ["title": "只归档", "minutes": "纪要", "send_receipt": false])
        let receipt = try XCTUnwrap(result["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["skipped"] as? Bool, true)
        XCTAssertEqual(transport.writeCount(path: "/im/v1/messages"), 0)
    }

    func testMeetingCloseoutRequiresTitleAndMinutes() async throws {
        let store = try store()
        do {
            _ = try await call(store, "meeting_closeout", ["title": "", "minutes": "x"])
            XCTFail("空标题应被拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("title 与 minutes"))
        }
    }

    func testWritesAreStillHighRiskWithAnIdempotencyKey() throws {
        let store = try store()
        XCTAssertTrue(store.activeToolDeclarations.contains { $0.name == "plugin__feishu_calendar__bot_create_doc" })
        for tool in ["bot_create_doc", "bot_send_message", "create_event", "meeting_closeout"] {
            XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__feishu_calendar__\(tool)"), tool)
        }
    }
}

/// Records every request so the test can prove a second write never reached Feishu.
private final class RecordingTransport: DesktopPluginHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func send(request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { requests.append(request) }
        let path = request.url?.path ?? ""
        if path.contains("tenant_access_token") {
            return (Data(#"{"code":0,"tenant_access_token":"t-test","expire":7200}"#.utf8), 200)
        }
        if path.contains("/docx/v1/documents") {
            return (Data(#"{"code":0,"data":{"document":{"document_id":"doxcn_test"}}}"#.utf8), 200)
        }
        if path.contains("/im/v1/messages") {
            return (Data(#"{"code":0,"data":{"message_id":"om_test"}}"#.utf8), 200)
        }
        return (Data(#"{"code":0}"#.utf8), 200)
    }

    /// Writes only: GETs (list/read) are intentionally not counted.
    func writeCount(path: String) -> Int {
        lock.withLock { requests.filter { ($0.url?.path ?? "").contains(path) && ($0.httpMethod ?? "GET") != "GET" }.count }
    }
}
