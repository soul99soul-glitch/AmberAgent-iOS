import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class NovelAppToolHostTests: XCTestCase {
    private func makeSettings(webSearch: Bool) -> NovelAppSettingsStore {
        let suite = "novel.toolhost.tests.\(UUID().uuidString)"
        let store = NovelAppSettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            credentials: MemoryCredentials()
        )
        store.save(
            services: [],
            defaultModelID: nil,
            searchServices: store.searchServices,
            selectedSearchID: store.selectedSearchID,
            resultSize: 5,
            webSearchEnabled: webSearch
        )
        return store
    }

    func testAskUserIsAlwaysAvailable() {
        let host = NovelAppToolHost(settings: makeSettings(webSearch: false))
        XCTAssertNotNil(host.novelDiscussionToolExecutors(projectContext: nil)["ask_user"])
    }

    func testSearchToolsFollowTheWebSearchSwitch() {
        let off = NovelAppToolHost(settings: makeSettings(webSearch: false))
        XCTAssertTrue(Set(off.novelDiscussionToolExecutors(projectContext: nil).keys).isDisjoint(with: IOSSearchExecutor.supportedToolNames))

        let on = NovelAppToolHost(settings: makeSettings(webSearch: true))
        XCTAssertTrue(IOSSearchExecutor.supportedToolNames.isSubset(of: Set(on.novelDiscussionToolExecutors(projectContext: nil).keys)))
    }

    func testProjectToolsOnlyWithProjectContext() {
        let host = NovelAppToolHost(settings: makeSettings(webSearch: false))
        let names = Set(IOSNovelProjectToolExecutor.supportedToolNames)
        XCTAssertTrue(Set(host.novelDiscussionToolExecutors(projectContext: nil).keys).isDisjoint(with: names))

        let context = NovelProjectToolRunContext(projectID: NovelProjectID(UUID()), branchID: NovelBranchID(UUID()))
        XCTAssertTrue(names.isSubset(of: Set(host.novelDiscussionToolExecutors(projectContext: context).keys)))
    }
}
