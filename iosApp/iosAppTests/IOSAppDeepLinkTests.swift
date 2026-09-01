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

    @Test func generatedURLsRoundTrip() throws {
        let destinations: [IOSAppDeepLink.Destination] = [
            .newConversation, .latestConversation, .conversation(id: "ABC_123"),
            .agentPrompt(handoffID: "handoff-123"), .activeTask,
            .healthSummary, .weather, .appleIntegrations
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
