import XCTest
@testable import AmberDeepRead

final class DeepReadCredentialStorageTests: XCTestCase {
    func testRealKeychainWritesUpdatesAndDeletesIsolatedCredential() throws {
        let storage = DeepReadKeychainStorage()
        let account = "test.\(UUID().uuidString)"
        defer { try? storage.write("", account: account) }
        XCTAssertNil(try storage.read(account: account))
        try storage.write("test-credential-first", account: account)
        XCTAssertEqual(try storage.read(account: account), "test-credential-first")
        try storage.write("test-credential-updated", account: account)
        XCTAssertEqual(try storage.read(account: account), "test-credential-updated")
        try storage.write("", account: account)
        XCTAssertNil(try storage.read(account: account))
    }
}
