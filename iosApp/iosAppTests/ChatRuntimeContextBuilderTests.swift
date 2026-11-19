import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatRuntimeContextBuilderTests: XCTestCase {
    func testWorkspaceArtifactsIndexInjectsTopFiveBoundedAndEscaped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextBuilderArtifacts-\(UUID().uuidString)")
        let suite = "ContextBuilderArtifacts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let workspace = IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("ws", isDirectory: true))
        for idx in 1...6 {
            try workspace.saveArtifact(
                title: idx == 6 ? "Newest <script> & \"Quote\"" : "Artifact \(idx)",
                content: "Long artifact body #\(idx) " + String(repeating: "abc ", count: 40),
                type: .note,
                sourceKind: "chat",
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(idx * 10))
            )
        }

        let index = try XCTUnwrap(workspace.recentArtifactsPromptIndex(limit: 5, maxChars: 600))
        XCTAssertLessThanOrEqual(index.count, 600)
        XCTAssertTrue(index.hasPrefix("<untrusted_workspace_artifacts"))
        XCTAssertTrue(index.hasSuffix("</untrusted_workspace_artifacts>"))
        XCTAssertTrue(index.contains("Newest &lt;script&gt; &amp; &quot;Quote&quot;"))
        XCTAssertFalse(index.contains("<script>"))
        XCTAssertTrue(index.contains("Artifact 5"))
        XCTAssertTrue(index.contains("Artifact 2"))
        XCTAssertFalse(index.contains("Artifact 1:"))

        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let miniApps = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let builder = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: miniApps,
            miniAppRuntimeEnabled: false,
            workspaceStore: workspace
        )

        let prepared = builder.injectingRuntimeContext(into: [UIMessage.companion.user(prompt: "hi")])
        let systemText = prepared.filter { $0.role == MessageRole.system }.map { $0.toText() }.joined(separator: "\n")
        XCTAssertTrue(systemText.contains("<untrusted_workspace_artifacts"))
        XCTAssertTrue(systemText.contains("Newest &lt;script&gt; &amp; &quot;Quote&quot;"))
    }

    func testWorkspaceArtifactsIndexOmittedWhenHubIsolatedOrWorkspaceDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextBuilderIsolated-\(UUID().uuidString)")
        let suite = "ContextBuilderIsolated-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hubs = AmberHubStore.shared
        let oldHubs = hubs.hubs
        defer {
            hubs.hubs = oldHubs
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let workspace = IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("ws", isDirectory: true))
        try workspace.saveArtifact(title: "Secret Plan", content: "Confidential body", type: .note, sourceKind: "chat")

        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let miniApps = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let isolatedConvId = UUID().uuidString
        hubs.hubs.append(AmberHubItem(title: "Isolated", memoryPolicy: .hubIsolated, conversationIds: [isolatedConvId]))

        let isolatedBuilder = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: miniApps,
            miniAppRuntimeEnabled: false,
            workspaceStore: workspace,
            conversationId: isolatedConvId
        )
        let isolatedPrepared = isolatedBuilder.injectingRuntimeContext(into: [UIMessage.companion.user(prompt: "hi")])
        let isolatedText = isolatedPrepared.filter { $0.role == MessageRole.system }.map { $0.toText() }.joined(separator: "\n")
        XCTAssertFalse(isolatedText.contains("<untrusted_workspace_artifacts"))

        let emptyWorkspace = IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("empty-ws", isDirectory: true))
        let emptyBuilder = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: miniApps,
            miniAppRuntimeEnabled: false,
            workspaceStore: emptyWorkspace
        )
        let emptyPrepared = emptyBuilder.injectingRuntimeContext(into: [UIMessage.companion.user(prompt: "hi")])
        let emptyText = emptyPrepared.filter { $0.role == MessageRole.system }.map { $0.toText() }.joined(separator: "\n")
        XCTAssertFalse(emptyText.contains("<untrusted_workspace_artifacts"))
    }
}
