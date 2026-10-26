import Foundation
import XCTest
@testable import AmberMac

@MainActor final class DesktopRecipeTests: XCTestCase {
    private let fixture = #"{"schema":"amber.recipe.v1","name":"digest_save","version":"1.0.0","description":"列目录并写入工作区","inputs":{"output_path":"string"},"steps":[{"id":"list","tool":"tools_list","arguments":{}},{"id":"save","tool":"workspace_file_write","arguments":{"path":"${input.output_path}","content":"${step.list.output.status}"}}],"outputs":{"file_path":"${step.save.output.path}"}}"#
    private let tools: Set<String> = ["tools_list", "workspace_file_write"]

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("amber-recipe-" + UUID().uuidString) }
    private func installed(_ root: URL, json: String? = nil) throws -> DesktopRecipeStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recipe.json")
        try Data((json ?? fixture).utf8).write(to: source)
        let store = DesktopRecipeStore(directory: root.appendingPathComponent("Installed"), registeredTools: tools)
        try store.importRecipe(from: source)
        return store
    }

    func testIOSWireRecipeBindsInputsAndPreviousOutputAndWritesActualFile() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try installed(root)
        let calls = RecipeCalls()
        let disabled = await store.run(name: "digest_save", inputs: ["output_path": .string("result.txt")]) { _, _ in calls.names.append("unexpected"); return "{}" }
        XCTAssertFalse(disabled.succeeded)
        XCTAssertTrue(calls.names.isEmpty)
        try store.setEnabled("digest_save", enabled: true)
        let result = await store.run(name: "digest_save", inputs: ["output_path": .string("result.txt")]) { name, json in
            calls.names.append(name)
            if name == "tools_list" { return #"{"status":"真实目录摘要"}"# }
            let args = try JSONDecoder().decode([String: DesktopRecipeJSONValue].self, from: Data(json.utf8))
            guard case .string(let path) = args["path"], case .string(let content) = args["content"] else { throw DesktopRuntimeError.message("Binding type lost") }
            try Data(content.utf8).write(to: root.appendingPathComponent(path))
            return #"{"ok":true,"path":"result.txt"}"#
        }
        XCTAssertTrue(result.succeeded, result.error ?? "")
        XCTAssertEqual(result.completedSteps, ["list", "save"])
        XCTAssertEqual(calls.names, ["tools_list", "workspace_file_write"])
        XCTAssertEqual(result.outputs["file_path"], .string("result.txt"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8), "真实目录摘要")
        let edited = fixture.replacingOccurrences(of: "1.0.0", with: "1.1.0")
        try store.saveRecipe(name: "digest_save", json: edited)
        let restarted = DesktopRecipeStore(directory: store.directory, registeredTools: tools)
        XCTAssertNil(restarted.loadError)
        XCTAssertTrue(restarted.recipes.first?.enabled == true)
        XCTAssertEqual(restarted.recipes.first?.manifest.version, "1.1.0")
        try restarted.setEnabled("digest_save", enabled: false)
        XCTAssertFalse(DesktopRecipeStore(directory: store.directory, registeredTools: tools).recipes.first?.enabled ?? true)
        try restarted.deleteRecipe(name: "digest_save")
        XCTAssertTrue(DesktopRecipeStore(directory: store.directory, registeredTools: tools).recipes.isEmpty)
    }

    func testValidationRejectsForwardMissingMalformedRecursiveAndUnregisteredCalls() throws {
        let invalid = [
            fixture.replacingOccurrences(of: "amber.recipe.v1", with: "amber.recipe.v2"),
            fixture.replacingOccurrences(of: "tools_list", with: "recipe__digest_save"),
            fixture.replacingOccurrences(of: "tools_list", with: "not_registered"),
            fixture.replacingOccurrences(of: "${input.output_path}", with: "${input.missing}"),
            fixture.replacingOccurrences(of: "${input.output_path}", with: "${step.save.output.path}"),
            fixture.replacingOccurrences(of: "${input.output_path}", with: "${input.output_path"),
            fixture.replacingOccurrences(of: "${step.save.output.path}", with: "${input.output_path}"),
            fixture.replacingOccurrences(of: #""name":"digest_save""#, with: #""name":"digest_save\n""#),
        ]
        for json in invalid {
            let manifest = try JSONDecoder().decode(DesktopRecipeManifest.self, from: Data(json.utf8))
            XCTAssertThrowsError(try manifest.validated(registeredTools: tools), json)
        }
        let manifest = DesktopRecipeManifest(name: "too_many", version: "1", description: "九个步骤", inputs: [:],
            steps: (1...9).map { DesktopRecipeStep(id: "s\($0)", tool: "tools_list", arguments: [:]) }, outputs: [:])
        XCTAssertThrowsError(try manifest.validated(registeredTools: tools))
    }

    func testFirstPrimitiveFailureNeverDispatchesLaterSteps() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try installed(root)
        try store.setEnabled("digest_save", enabled: true)
        let calls = RecipeCalls()
        let failed = await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in
            calls.names.append(name); throw DesktopRuntimeError.message("真实失败")
        }
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.failedStep, "list")
        XCTAssertEqual(failed.completedSteps, [])
        XCTAssertEqual(calls.names, ["tools_list"])
        calls.names = []
        let failedJSON = await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in
            calls.names.append(name); return #"{"ok":false,"error":"denied"}"#
        }
        XCTAssertFalse(failedJSON.succeeded)
        XCTAssertEqual(calls.names, ["tools_list"])
    }

    func testMissingRuntimeBindingAndBadInputsDoNotReachNextPrimitive() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try installed(root)
        try store.setEnabled("digest_save", enabled: true)
        let calls = RecipeCalls()
        let result = await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in calls.names.append(name); return #"{"wrong_field":"value"}"# }
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.completedSteps, ["list"])
        XCTAssertEqual(result.failedStep, "save")
        XCTAssertTrue(result.error?.contains("status") == true)
        XCTAssertEqual(calls.names, ["tools_list"])
        calls.names = []
        let badInputs = await store.run(name: "digest_save", inputs: ["output_path": .number(3)]) { name, _ in calls.names.append(name); return "{}" }
        XCTAssertFalse(badInputs.succeeded)
        XCTAssertTrue(calls.names.isEmpty)
        store.registeredTools = []
        let unavailable = await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in calls.names.append(name); return "{}" }
        XCTAssertFalse(unavailable.succeeded)
        XCTAssertTrue(calls.names.isEmpty)
    }

    func testCancellationStopsTheActivePrimitiveAndNeverRunsTheNext() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try installed(root)
        try store.setEnabled("digest_save", enabled: true)
        let calls = RecipeCalls(), started = AsyncStream<Void>.makeStream()
        let task = Task { await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in
            calls.names.append(name); started.continuation.yield(())
            try await Task.sleep(for: .seconds(10)); return "{}"
        } }
        for await _ in started.stream { break }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("取消") == true)
        XCTAssertEqual(calls.names, ["tools_list"])
    }

    func testStepTimeoutStopsWithoutDispatchingLaterSteps() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let timed = fixture.replacingOccurrences(of: #""id":"list""#, with: #""id":"list","timeoutSeconds":1"#)
        let store = try installed(root, json: timed)
        try store.setEnabled("digest_save", enabled: true)
        let calls = RecipeCalls(), start = ContinuousClock.now
        let result = await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in
            calls.names.append(name); try await Task.sleep(for: .seconds(10)); return "{}"
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("超时") == true)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(calls.names, ["tools_list"])
    }

    func testConfirmedPrimitiveOutputIsKeptWhenCancellationArrivesBeforeTheNextStep() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try installed(root)
        try store.setEnabled("digest_save", enabled: true)
        let calls = RecipeCalls()
        let task = Task { await store.run(name: "digest_save", inputs: ["output_path": .string("out")]) { name, _ in
            calls.names.append(name)
            calls.task?.cancel()
            return #"{"status":"confirmed"}"#
        } }
        calls.task = task
        let result = await task.value
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.completedSteps, ["list"])
        XCTAssertEqual(calls.names, ["tools_list"])
    }
}

@MainActor private final class RecipeCalls {
    var names: [String] = []
    var task: Task<DesktopRecipeRunResult, Never>?
}
