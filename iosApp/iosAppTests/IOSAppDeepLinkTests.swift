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
    }

    @Test func rejectsWrongSchemeQueriesAndUnsafeIdentifiers() throws {
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "https://conversation/new")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/new?redirect=https://example.com")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://conversation/a%2Fb")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://unknown/path")), expectedScheme: scheme) == nil)
    }

    @Test func generatedURLsRoundTrip() throws {
        let destinations: [IOSAppDeepLink.Destination] = [
            .newConversation, .latestConversation, .conversation(id: "ABC_123"),
            .activeTask, .healthSummary, .weather, .appleIntegrations
        ]
        for destination in destinations {
            let url = try #require(IOSAppDeepLink.url(for: destination, scheme: scheme))
            #expect(IOSAppDeepLink.parse(url, expectedScheme: scheme) == destination)
        }
    }
}
