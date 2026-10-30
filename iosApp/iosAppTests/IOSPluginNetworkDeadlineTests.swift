import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPluginNetworkDeadlineTests: IOSRecipeIntegrationTestCase {
    func testOpenAPICancellationDoesNotWaitForSystemDNS() async throws {
        let runtime = makeRuntime(root: tempRoot(), ledger: IOSRunEventLogLedger(log: IOSRunEventLog()))
        let execution = ChatPluginExecution(runtime: runtime)
        let started = expectation(description: "DNS started")
        let finished = expectation(description: "cancelled caller returned")
        let releaseDNS = DispatchSemaphore(value: 0)
        defer { releaseDNS.signal() }
        let remote = IOSPluginRemoteManifest(kind: .openapi, url: "https://example.com/lookup", method: "GET")
        let task = Task { @MainActor in
            let output = await execution.executePluginRemote(
                remote,
                descriptor: descriptor(remote: remote, timeoutMs: 5_000),
                argumentsJSON: "{}",
                resolveHost: { _ in
                    started.fulfill()
                    releaseDNS.wait()
                    return ["1.1.1.1"]
                }
            )
            finished.fulfill()
            return output
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        releaseDNS.signal()
        let output = await task.value
        XCTAssertEqual(try parse(output)?["ok"] as? Bool, false, output)
    }

    func testOpenAPITimeoutIncludesSystemDNS() async throws {
        let runtime = makeRuntime(root: tempRoot(), ledger: IOSRunEventLogLedger(log: IOSRunEventLog()))
        let execution = ChatPluginExecution(runtime: runtime)
        let started = expectation(description: "DNS started")
        let finished = expectation(description: "DNS deadline returned")
        let releaseDNS = DispatchSemaphore(value: 0)
        defer { releaseDNS.signal() }
        let remote = IOSPluginRemoteManifest(kind: .openapi, url: "https://example.com/lookup", method: "GET")
        let task = Task { @MainActor in
            let output = await execution.executePluginRemote(
                remote,
                descriptor: descriptor(remote: remote, timeoutMs: 100),
                argumentsJSON: "{}",
                resolveHost: { _ in
                    started.fulfill()
                    releaseDNS.wait()
                    return ["1.1.1.1"]
                }
            )
            finished.fulfill()
            return output
        }
        await fulfillment(of: [started], timeout: 1)
        await fulfillment(of: [finished], timeout: 1)
        releaseDNS.signal()
        let output = await task.value
        XCTAssertEqual(try parse(output)?["ok"] as? Bool, false, output)
    }

    private func descriptor(remote: IOSPluginRemoteManifest, timeoutMs: Int) -> IOSDynamicRecipeToolDescriptor {
        IOSDynamicRecipeToolDescriptor(
            toolId: "plugin__deadline__lookup",
            recipeName: "lookup",
            pluginId: "deadline",
            capabilityBroker: IOSPluginCapabilityBroker(
                pluginId: "deadline",
                primitiveTools: [],
                capabilities: IOSPluginCapabilities(networkDomains: ["example.com"])
            ),
            version: "1.0.0",
            manifestHash: "deadline-test",
            permissionSummary: "read-only remote lookup",
            effectClassRawValue: IOSToolEffectClass.pure.rawValue,
            inputsJSON: "{}",
            description: "DNS deadline regression",
            implementation: .remote(remote),
            outputType: .json,
            timeoutMs: timeoutMs,
            maxOutputChars: 4_000,
            backgroundAllowed: false,
            searchInfoJSON: "{}"
        )
    }
}
