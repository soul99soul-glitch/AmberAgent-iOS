import Foundation
import Testing
@testable import iosApp

@Suite("App deep links")
struct IOSAppDeepLinkTests {
    private let scheme = "amber-test"

    @Test func parsesOwnedDestinations() throws {
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/new")), expectedScheme: scheme) == .newConversation)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/latest")), expectedScheme: scheme) == .latestConversation)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/abc-123")), expectedScheme: scheme) == .conversation(id: "abc-123"))
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://task/active")), expectedScheme: scheme) == .activeTask)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://settings/weather")), expectedScheme: scheme) == .weather)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://agent/ask/handoff-123")), expectedScheme: scheme) == .agentPrompt(handoffID: "handoff-123"))
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/wt_signal-01")), expectedScheme: scheme) == .proactiveSignal(id: "wt_signal-01"))
    }

    @Test func rejectsWrongSchemeQueriesAndUnsafeIdentifiers() throws {
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "https://conversation/new")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/new?redirect=https://example.com")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/a%2Fb")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://unknown/path")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://agent/ask?prompt=hello")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://agent/ask/handoff-123?extra=1")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.url(for: .agentPrompt(handoffID: "unsafe/id"), scheme: scheme) == nil)
    }

    @Test func proactiveSignalDeepLinkValidatesAndRoundTrips() throws {
        let maxLenID = String(repeating: "a", count: 48)
        let overLenID = String(repeating: "a", count: 49)

        let maxURL = try #require(IOSAppDeepLink.url(for: .proactiveSignal(id: maxLenID), scheme: scheme))
        #expect(maxURL.absoluteString == "amber-test://proactive/\(maxLenID)")
        #expect(IOSAppDeepLink.parse(maxURL, expectedScheme: scheme) == .proactiveSignal(id: maxLenID))

        let typicalURL = try #require(IOSAppDeepLink.url(for: .proactiveSignal(id: "wk_12345abcde_99"), scheme: scheme))
        #expect(IOSAppDeepLink.parse(typicalURL, expectedScheme: scheme) == .proactiveSignal(id: "wk_12345abcde_99"))

        // Reject empty, overlong, path traversal, query, fragment, wrong scheme, and illegal characters.
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/\(overLenID)")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/..")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/../secret")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/a%2Fb")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/a/b")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive//sig_1")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/sig_1?x=1")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/sig_1#frag")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://proactive/sig:1")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "https://proactive/sig_1")), expectedScheme: scheme) == nil)

        #expect(IOSAppDeepLink.url(for: .proactiveSignal(id: ""), scheme: scheme) == nil)
        #expect(IOSAppDeepLink.url(for: .proactiveSignal(id: overLenID), scheme: scheme) == nil)
        #expect(IOSAppDeepLink.url(for: .proactiveSignal(id: "../escape"), scheme: scheme) == nil)
        #expect(IOSAppDeepLink.url(for: .proactiveSignal(id: "bad:id"), scheme: scheme) == nil)
    }

    @Test func generatedURLsRoundTrip() throws {
        let destinations: [IOSAppDeepLink.Destination] = [
            .newConversation, .latestConversation, .conversation(id: "ABC_123"),
            .agentPrompt(handoffID: "handoff-123"), .activeTask,
            .healthSummary, .weather, .appleIntegrations,
            .proactiveSignal(id: "wt_demo-01")
        ]
        for destination in destinations {
            let url = try #require(IOSAppDeepLink.url(for: destination, scheme: scheme))
            #expect(IOSAppDeepLink.parse(url, expectedScheme: scheme) == destination)
        }
    }

    @Test func normalizesPromptAtTheDeepLinkBoundary() {
        #expect(IOSAppDeepLink.normalizedPrompt("  安排午餐  ") == "安排午餐")
        #expect(IOSAppDeepLink.normalizedPrompt("") == nil)
        #expect(IOSAppDeepLink.normalizedPrompt(String(repeating: "a", count: 2_001)) == nil)
    }

    @Test @MainActor func promptHandoffIsOpaqueAndSingleUse() throws {
        let destination = try #require(IOSDeepLinkInbox.shared.preparePromptHandoff("分析今天安排"))
        let url = try #require(IOSAppDeepLink.url(for: destination, scheme: scheme))
        #expect(!url.absoluteString.contains("分析今天安排"))
        #expect(IOSAppDeepLink.parse(url, expectedScheme: scheme) == destination)

        guard case .agentPrompt(let handoffID) = destination else {
            Issue.record("Expected an agent prompt handoff")
            return
        }
        #expect(IOSDeepLinkInbox.shared.consumePromptHandoff(id: handoffID) == "分析今天安排")
        #expect(IOSDeepLinkInbox.shared.consumePromptHandoff(id: handoffID) == nil)
    }
}
