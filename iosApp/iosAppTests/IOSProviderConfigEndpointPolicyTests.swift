import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSProviderConfigEndpointPolicyTests: XCTestCase {
    func testCreateRejectsEndpointsTheChatRuntimeCannotUseWithoutWriting() async throws {
        let store = makeStore()
        let service = IOSProviderConfigToolService(sharedSettings: store)
        let providerIDs = store.snapshot.providers.map { $0.id.description() }
        let revision = store.revision

        for endpoint in ["https:/missing-host", "http://localhost:11434/v1"] {
            let output = try await execute(service, tool: "provider_config_create", arguments: [
                "name": "Rejected endpoint",
                "base_url": endpoint,
            ])

            XCTAssertEqual(output["ok"] as? Bool, false, endpoint)
            XCTAssertEqual(store.snapshot.providers.map { $0.id.description() }, providerIDs)
            XCTAssertEqual(store.revision, revision)
        }
    }

    func testApplyRejectsInvalidEndpointBeforeChangingOtherFields() async throws {
        let store = makeStore()
        let service = IOSProviderConfigToolService(sharedSettings: store)
        let created = try await execute(service, tool: "provider_config_create", arguments: [
            "name": "Original endpoint",
            "base_url": "https://provider.example/v1",
        ])
        let providerID = try XCTUnwrap(created["provider_id"] as? String)
        let before = try provider(in: store, id: providerID)
        let revision = store.revision

        for endpoint in ["https:/missing-host", "http://localhost:11434/v1"] {
            let output = try await execute(service, tool: "provider_config_apply", arguments: [
                "provider_id": providerID,
                "name": "Should not change",
                "enabled": false,
                "base_url": endpoint,
            ])

            XCTAssertEqual(output["ok"] as? Bool, false, endpoint)
            let after = try provider(in: store, id: providerID)
            XCTAssertEqual(after.baseUrl, before.baseUrl)
            XCTAssertEqual(after.name, before.name)
            XCTAssertEqual(after.enabled, before.enabled)
            XCTAssertEqual(store.revision, revision)
        }
    }

    func testCreateAndApplyBothAcceptHTTPIPAddressEndpoints() async throws {
        let store = makeStore()
        let service = IOSProviderConfigToolService(sharedSettings: store)

        for host in ["192.168.1.3", "10.0.0.1"] {
            let initialEndpoint = "http://\(host):11434/v1"
            let created = try await execute(service, tool: "provider_config_create", arguments: [
                "name": "Local model \(host)",
                "base_url": initialEndpoint,
            ])
            XCTAssertEqual(created["ok"] as? Bool, true, initialEndpoint)
            let providerID = try XCTUnwrap(created["provider_id"] as? String)
            XCTAssertEqual(try provider(in: store, id: providerID).baseUrl, initialEndpoint)

            let changedEndpoint = "http://\(host):11435/v1"
            let applied = try await execute(service, tool: "provider_config_apply", arguments: [
                "provider_id": providerID,
                "base_url": changedEndpoint,
            ])
            XCTAssertEqual(applied["ok"] as? Bool, true, changedEndpoint)
            XCTAssertEqual(try provider(in: store, id: providerID).baseUrl, changedEndpoint)
        }
    }

    private func makeStore() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: "ProviderEndpointPolicy-\(UUID().uuidString)")!)
    }

    private func provider(in store: IOSSharedSettingsStore, id: String) throws -> ProviderSetting.OpenAI {
        try XCTUnwrap(store.snapshot.providers.first { $0.id.description() == id } as? ProviderSetting.OpenAI)
    }

    private func execute(
        _ service: IOSProviderConfigToolService,
        tool: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await service.execute(toolName: tool, argumentsJSON: String(decoding: input, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
