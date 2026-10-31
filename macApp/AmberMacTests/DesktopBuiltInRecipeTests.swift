import XCTest
@testable import AmberMac

/// M3.3/M3.5: the two P3 workflows ship as real `amber.recipe.v1` manifests, so they stay inspectable and each step
/// keeps its own approval card.
@MainActor final class DesktopBuiltInRecipeTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-builtin-recipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// The tools the manifests name must be the ones the plugins actually register, or the Recipe would be
    /// rejected at enable time and the workflow would silently never run.
    private func registeredTools() -> Set<String> {
        var names = Set(DesktopToolRegistry.declarations.map(\.name))
        names.formUnion(["plugin__watchtower__snapshot", "plugin__watchtower__status",
                         "plugin__feishu_calendar__meeting_closeout"])
        return names
    }

    func testManifestsValidateAgainstTheRealToolNames() throws {
        let tools = registeredTools()
        for manifest in DesktopBuiltInRecipes.manifests(hasFeishu: true) {
            XCTAssertNoThrow(try manifest.validated(registeredTools: tools), manifest.name)
        }
    }

    func testWatchRecipeFetchesThenCompares() throws {
        let manifest = DesktopBuiltInRecipes.watchPage
        XCTAssertEqual(manifest.schema, "amber.recipe.v1")
        XCTAssertEqual(manifest.steps.map(\.tool), ["scrape_web", "plugin__watchtower__snapshot"])
        // The snapshot needs the fetched body: it may never open a socket itself.
        let compare = try XCTUnwrap(manifest.steps.last)
        XCTAssertEqual(compare.arguments["content"], .string("${step.fetch.output.content}"))
        XCTAssertEqual(compare.arguments["url"], .string("${input.url}"))
        XCTAssertEqual(Set(manifest.outputs.keys), ["changed", "quiet", "added"])
    }

    func testMeetingRecipeIsASingleIdempotentCloseout() throws {
        let manifest = DesktopBuiltInRecipes.meetingLoop
        XCTAssertEqual(manifest.steps.count, 1, "读与纪要由对话完成，这里只固定两次外部写入")
        let step = try XCTUnwrap(manifest.steps.first)
        XCTAssertEqual(step.tool, "plugin__feishu_calendar__meeting_closeout")
        // Default key is computed by meeting_closeout from date, receive_id, title and minutes digest so recurring
        // meetings on different days never collide on "${input.title}" alone.
        XCTAssertNil(step.arguments["idempotency_key"])
        XCTAssertEqual(Set(manifest.outputs.keys), ["document_id", "url", "replayed"])
    }

    func testInstallWritesEnabledRecipesAndNeverOverwritesUserEdits() throws {
        let installed = DesktopBuiltInRecipes.install(into: root, hasFeishu: true)
        XCTAssertEqual(Set(installed), [DesktopBuiltInRecipes.watchPageName, DesktopBuiltInRecipes.meetingLoopName])

        let store = DesktopRecipeStore(directory: root, registeredTools: registeredTools())
        XCTAssertNil(store.loadError)
        XCTAssertEqual(Set(store.recipes.map(\.id)), [DesktopBuiltInRecipes.watchPageName, DesktopBuiltInRecipes.meetingLoopName])
        XCTAssertTrue(store.recipes.allSatisfy(\.enabled), "新装的流程默认启用，但每一步仍要批准")

        // A user edit survives the next launch.
        let edited = try XCTUnwrap(store.recipes.first { $0.id == DesktopBuiltInRecipes.watchPageName })
        try store.saveRecipe(name: edited.id, json: edited.json.replacingOccurrences(of: "1.0.0", with: "1.0.1"))
        XCTAssertTrue(DesktopBuiltInRecipes.install(into: root, hasFeishu: true).isEmpty)
        let reloaded = DesktopRecipeStore(directory: root, registeredTools: registeredTools())
        XCTAssertEqual(reloaded.recipes.first { $0.id == DesktopBuiltInRecipes.watchPageName }?.manifest.version, "1.0.1")
    }

    func testMeetingRecipeIsSkippedWhenFeishuIsDisabled() throws {
        let installed = DesktopBuiltInRecipes.install(into: root, hasFeishu: false)
        XCTAssertEqual(installed, [DesktopBuiltInRecipes.watchPageName])
        let store = DesktopRecipeStore(directory: root, registeredTools: registeredTools())
        XCTAssertEqual(store.recipes.map(\.id), [DesktopBuiltInRecipes.watchPageName])
    }

    /// A Recipe that names an unregistered tool must fail loudly at import, not half-run later.
    func testWatchRecipeIsRejectedWhenItsToolsAreMissing() throws {
        let source = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(try DesktopBuiltInRecipes.watchPage.canonicalJSON().utf8)
            .write(to: source.appendingPathComponent("recipe.json"))
        let store = DesktopRecipeStore(directory: root.appendingPathComponent("installed"), registeredTools: ["workspace_file_list"])
        XCTAssertThrowsError(try store.importRecipe(from: source.appendingPathComponent("recipe.json"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("未注册工具"), error.localizedDescription)
        }
    }
}
