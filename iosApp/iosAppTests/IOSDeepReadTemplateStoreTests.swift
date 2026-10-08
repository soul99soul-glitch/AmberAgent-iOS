import Foundation
import XCTest
#if canImport(AmberDeepRead)
@testable import AmberDeepRead
#else
@testable import iosApp
#endif

@MainActor
final class IOSDeepReadTemplateStoreTests: XCTestCase {
    func testFailedSavePreservesPublishedAndPersistedTemplate() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fileManager = RejectingTemplateFileManager()
        let store = IOSDeepReadTemplateStore(baseDirectory: base, fileManager: fileManager)
        let original = try store.save(template())
        var edited = original
        edited.name = "Edited template"
        fileManager.rejectWrites = true

        XCTAssertThrowsError(try store.save(edited)) { error in
            XCTAssertEqual(error as? IOSDeepReadTemplateStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.templates, [original])
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(IOSDeepReadTemplateStore(baseDirectory: base).templates, [original])

        fileManager.rejectWrites = false
        let saved = try store.save(edited)
        XCTAssertEqual(store.templates, [saved])
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(IOSDeepReadTemplateStore(baseDirectory: base).templates, [saved])
    }

    func testFailedDeletePreservesPublishedAndPersistedTemplateAndCanRetry() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fileManager = RejectingTemplateFileManager()
        let store = IOSDeepReadTemplateStore(baseDirectory: base, fileManager: fileManager)
        let original = try store.save(template())
        fileManager.rejectWrites = true

        XCTAssertFalse(store.delete(id: original.id))
        XCTAssertEqual(store.templates, [original])
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(IOSDeepReadTemplateStore(baseDirectory: base).templates, [original])

        fileManager.rejectWrites = false
        XCTAssertTrue(store.delete(id: original.id))
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(IOSDeepReadTemplateStore(baseDirectory: base).templates.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deep-read-template-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func template() -> IOSDeepReadCustomTemplate {
        IOSDeepReadCustomTemplate(
            name: "Original template",
            description: "Saved before the failure",
            html: IOSDeepReadHTMLTemplateRenderer.starterHTML(),
            createdByAI: false
        )
    }
}

private final class RejectingTemplateFileManager: FileManager, @unchecked Sendable {
    var rejectWrites = false

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}
