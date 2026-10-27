import XCTest
@testable import AmberMac

/// Opt-in release measurements for the Workspace persistence hot path.
/// Run with AMBER_MAC_PERFORMANCE_BENCHMARK=1; ordinary runtime test runs skip this suite.
@MainActor final class RuntimePerformanceTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []

        func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
            DesktopMessage(id: id, role: .user, text: text)
        }

        func start(configuration: DesktopProviderConfiguration, apiKey: String,
                  messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration()
            runs.append(run)
            return run
        }
    }

    private func makeWorkspace(messageCount: Int) throws -> (DesktopWorkspace, Provider) {
        let defaults = UserDefaults(suiteName: "amber.performance.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var configuration = try XCTUnwrap(settings.selectedProvider)
        configuration.modelID = "performance-model"
        try settings.saveProvider(configuration, apiKey: "performance-key")

        let messages = (0..<messageCount).map { index in
            DesktopMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                           text: "历史消息 \(index) " + String(repeating: "内容 ", count: 4))
        }
        let conversation = DesktopConversation(messages: messages)
        let provider = Provider()
        let workspace = DesktopWorkspace(settings: settings,
                                         storage: DesktopMemoryConversationStorage([conversation]),
                                         provider: provider,
                                         initialConversations: [conversation])
        return (workspace, provider)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    func testPersistenceSaveMedianByMessageCount() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_MAC_PERFORMANCE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set AMBER_MAC_PERFORMANCE_BENCHMARK=1 to run performance measurements")
        }

        for messageCount in [500, 1_000, 2_000] {
            var samples: [Double] = []
            for trial in 0..<6 {
                let (workspace, provider) = try makeWorkspace(messageCount: messageCount)
                workspace.draft = "触发一次终态保存"
                workspace.send()
                // Exclude the initial user/assistant checkpoint from the measured interval.
                _ = await workspace.flush()

                let start = ContinuousClock.now
                try XCTUnwrap(provider.runs.first).yield(.complete)
                while workspace.isGenerating { await Task.yield() }
                _ = await workspace.flush()
                let elapsed = milliseconds(start.duration(to: ContinuousClock.now))
                if trial > 0 { samples.append(elapsed) }
            }
            let ordered = samples.sorted()
            let median = ordered[ordered.count / 2]
            let formattedSamples = ordered.map { String(format: "%.3f", $0) }.joined(separator: ",")
            print("PERF RuntimePerformanceTests messages=\(messageCount) median_ms=\(String(format: "%.3f", median)) samples_ms=\(formattedSamples)")
        }
    }
}
