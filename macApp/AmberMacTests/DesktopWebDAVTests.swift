import Foundation
import XCTest
@testable import AmberMac

@MainActor final class DesktopWebDAVTests: XCTestCase {
    private static let listing = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/dav/AmberAgent/macOS/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
      <D:response><D:href>/dav/AmberAgent/macOS/fixture.ambermacbackup</D:href><D:propstat><D:prop><D:displayname>fixture.ambermacbackup</D:displayname><D:getcontentlength>42</D:getcontentlength><D:getlastmodified>Fri, 23 Oct 2026 12:00:00 GMT</D:getlastmodified><D:getetag>"revision-1"</D:getetag></D:prop></D:propstat></D:response>
      <D:response><D:href>/dav/AmberAgent/macOS/ios.amberbackup</D:href><D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength></D:prop></D:propstat></D:response>
    </D:multistatus>
    """.utf8)

    func testActualSharedWebDAVClientParsesAndBuildsEveryNetworkOperation() async throws {
        let bytes = Data("opaque archive bytes".utf8)
        let transport = WebDAVFixtureTransport([
            // MKCOL per path level: AmberAgent, then AmberAgent/macOS.
            .init(207, Self.listing), .init(405), .init(405), .init(207, Self.listing),
            .init(405), .init(405), .init(201, headers: ["ETag": "\"uploaded\""]), .init(200, bytes), .init(204),
        ])
        let client = IOSWebDAVClient(config: IOSWebDAVConfig(baseURL: "https://dav.example.com/dav", path: "AmberAgent/macOS", username: "user", password: "secret"), transport: transport)
        try await client.testConnection()
        let resources = try await client.listResources()
        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources.first?.isCollection == true)
        XCTAssertEqual(resources[1].fileName, "fixture.ambermacbackup")
        XCTAssertEqual(resources[1].sizeBytes, 42)
        XCTAssertEqual(resources[1].etag, "revision-1")
        XCTAssertEqual(resources[1].modifiedAt, 1_792_756_800_000)
        let revision = try await client.upload(data: bytes, fileName: "unique.ambermacbackup", mimeType: "application/json", createOnly: true)
        XCTAssertEqual(revision, "uploaded")
        let downloaded = try await client.download(fileName: "unique.ambermacbackup")
        XCTAssertEqual(downloaded, bytes)
        try await client.delete(fileName: "unique.ambermacbackup")
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PROPFIND", "MKCOL", "MKCOL", "PROPFIND", "MKCOL", "MKCOL", "PUT", "GET", "DELETE"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Depth"), "0")
        XCTAssertEqual(requests[1].url?.path, "/dav/AmberAgent")
        XCTAssertEqual(requests[2].url?.path, "/dav/AmberAgent/macOS")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(requests[6].value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(requests[6].value(forHTTPHeaderField: "Authorization"), "Basic " + Data("user:secret".utf8).base64EncodedString())
        XCTAssertEqual(requests[6].url?.path, "/dav/AmberAgent/macOS/unique.ambermacbackup")
        XCTAssertEqual(transport.bodies[6], bytes)
        XCTAssertThrowsError(try client.makeRequest(method: "GET", fileName: "../outside.ambermacbackup"))
    }

    func testHTTPSCredentialBoundaryAndMalformedXMLAreExplicitFailures() async throws {
        let noNetwork = WebDAVFixtureTransport([])
        let insecure = IOSWebDAVClient(config: IOSWebDAVConfig(baseURL: "http://example.com/dav", username: "user", password: "secret"), transport: noNetwork)
        XCTAssertThrowsError(try insecure.makeRequest(method: "PROPFIND"))
        XCTAssertTrue(noNetwork.requests.isEmpty)
        let invalid = IOSWebDAVClient(config: IOSWebDAVConfig(baseURL: "https://example.com", path: ""), transport: WebDAVFixtureTransport([.init(207, Data("<D:multistatus><broken>".utf8))]))
        do { _ = try await invalid.listResources(); XCTFail("Malformed XML must not publish partial snapshots") } catch {}
    }

    func testDirectoryPathCannotEscapeBaseAndLiteralPercentNamesStayEncoded() throws {
        for path in ["..", "../private", "snapshots/../private", "./snapshots", "snapshots\\private", "snapshots\0private"] {
            var configuration = DesktopWebDAVConfiguration()
            configuration.baseURL = "https://dav.example.com/dav"
            configuration.path = path
            XCTAssertThrowsError(try configuration.validate(), path)
            let client = IOSWebDAVClient(config: .init(baseURL: configuration.baseURL, path: path))
            XCTAssertThrowsError(try client.makeRequest(method: "GET", fileName: "backup.ambermacbackup"), path)
        }
        for (path, expected) in [
            ("", "https://dav.example.com/dav/backup.ambermacbackup"),
            ("中文/100%", "https://dav.example.com/dav/%E4%B8%AD%E6%96%87/100%25/backup.ambermacbackup"),
            ("%2e%2E", "https://dav.example.com/dav/%252e%252E/backup.ambermacbackup"),
        ] {
            let client = IOSWebDAVClient(config: .init(baseURL: "https://dav.example.com/dav", path: path))
            XCTAssertEqual(try client.makeRequest(method: "GET", fileName: "backup.ambermacbackup").url?.absoluteString, expected)
        }
    }

    func testMacManagerPersistsPasswordSeparatelyAndUsesUniqueCreateOnlySnapshots() async throws {
        let defaults = UserDefaults(suiteName: "amber.webdav.tests.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let archive = try DesktopBackup.encode(DesktopBackupPayload(), password: "backup-password")
        let transport = WebDAVFixtureTransport([
            .init(405), .init(207, Self.listing),
            .init(405), .init(201, headers: ["ETag": "\"r1\""]), .init(405), .init(201, headers: ["ETag": "\"r2\""]),
            .init(200, archive), .init(204),
        ])
        let manager = DesktopWebDAVManager(defaults: defaults, credentials: credentials, transport: transport)
        var configuration = DesktopWebDAVConfiguration()
        configuration.baseURL = "https://dav.example.com/dav"
        configuration.username = "user"
        try manager.save(configuration: configuration, password: "remote-secret")
        let restored = DesktopWebDAVManager(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.configuration, configuration)
        XCTAssertEqual(try restored.storedPassword(), "remote-secret")
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "app.amber.macos.webdav")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("remote-secret"))
        try await manager.list()
        XCTAssertEqual(manager.snapshots.map(\.fileName), ["fixture.ambermacbackup"])
        let first = try await manager.push(data: archive), second = try await manager.push(data: archive)
        XCTAssertNotEqual(first.fileName, second.fileName)
        XCTAssertTrue(first.fileName.hasSuffix(".ambermacbackup"))
        let downloaded = try await manager.download(first)
        XCTAssertEqual(downloaded, archive)
        XCTAssertEqual(try DesktopBackup.decode(downloaded, password: "backup-password").conversations.count, 0)
        try await manager.delete(first)
        XCTAssertFalse(manager.snapshots.contains(first))
        let puts = transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertTrue(puts.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == "*" })
        XCTAssertNotEqual(puts[0].url, puts[1].url)
    }

    func testMalformedSavedConfigCannotBeReplacedAndPreconditionFailureDoesNotOverwrite() async throws {
        let defaults = UserDefaults(suiteName: "amber.webdav.invalid.\(UUID().uuidString)")!
        let bytes = Data("corrupt saved config".utf8)
        defaults.set(bytes, forKey: "app.amber.macos.webdav")
        let bad = DesktopWebDAVManager(defaults: defaults, credentials: DesktopMemoryCredentials())
        var configuration = DesktopWebDAVConfiguration()
        configuration.baseURL = "https://example.com"
        XCTAssertThrowsError(try bad.save(configuration: configuration, password: ""))
        XCTAssertEqual(defaults.data(forKey: "app.amber.macos.webdav"), bytes)
        let transport = WebDAVFixtureTransport([.init(405), .init(412)])
        let manager = DesktopWebDAVManager(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials(), transport: transport)
        try manager.save(configuration: configuration, password: "")
        do {
            _ = try await manager.push(data: DesktopBackup.encode(DesktopBackupPayload(), password: "password"))
            XCTFail("Existing object must never be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("412")) }
        XCTAssertTrue(manager.snapshots.isEmpty)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testCancelStopsTheOwnedNetworkTaskWithoutPublishingSnapshots() async throws {
        let manager = DesktopWebDAVManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: DesktopMemoryCredentials(), transport: HangingWebDAVTransport())
        var configuration = DesktopWebDAVConfiguration()
        configuration.baseURL = "https://example.com"
        try manager.save(configuration: configuration, password: "")
        let task = Task { try await manager.list() }
        for _ in 0..<100 {
            if manager.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(manager.isBusy)
        manager.cancel()
        do { try await task.value; XCTFail("Cancelled request must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(manager.snapshots.isEmpty)
        XCTAssertEqual(manager.status, "操作已取消")
    }

    func testRemoteUploadRejectsUnencryptedOrNonBackupBytesBeforeNetwork() async throws {
        let transport = WebDAVFixtureTransport([])
        let manager = DesktopWebDAVManager(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials(), transport: transport)
        var configuration = DesktopWebDAVConfiguration()
        configuration.baseURL = "https://example.com"
        try manager.save(configuration: configuration, password: "")
        let plain = try DesktopBackup.encode(DesktopBackupPayload(), password: nil)
        for data in [plain, Data("not a backup".utf8)] {
            do { _ = try await manager.push(data: data); XCTFail("Remote upload requires a valid encrypted Mac archive") } catch {}
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRemoteIdentityComesFromHrefAndPercentDecodesExactlyOnce() async throws {
        let xml = Data("""
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/real.ambermacbackup</D:href><D:propstat><D:prop><D:displayname>旅行备份</D:displayname></D:prop></D:propstat></D:response>
          <D:response><D:href>/dav/real%20%2520.ambermacbackup</D:href><D:propstat><D:prop><D:displayname>wrong-target.ambermacbackup</D:displayname></D:prop></D:propstat></D:response>
        </D:multistatus>
        """.utf8)
        let transport = WebDAVFixtureTransport([.init(207, xml), .init(200, Data("bytes".utf8)), .init(204)])
        let manager = DesktopWebDAVManager(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials(), transport: transport)
        var configuration = DesktopWebDAVConfiguration()
        configuration.baseURL = "https://example.com/dav"
        configuration.path = ""
        try manager.save(configuration: configuration, password: "")
        try await manager.list()
        XCTAssertEqual(manager.snapshots.count, 2)
        XCTAssertEqual(manager.snapshots.map(\.remoteFileName).sorted(), ["real %20.ambermacbackup", "real.ambermacbackup"])
        XCTAssertTrue(manager.snapshots.contains { $0.displayName == "旅行备份" })
        let escaped = try XCTUnwrap(manager.snapshots.first { $0.displayName == "wrong-target.ambermacbackup" })
        _ = try await manager.download(escaped)
        try await manager.delete(escaped)
        XCTAssertEqual(transport.requests[1].url?.absoluteString, "https://example.com/dav/real%20%2520.ambermacbackup")
        XCTAssertEqual(transport.requests[2].url, transport.requests[1].url)
    }

    func testAlreadyCancelledCallerCannotStartAnUpload() async throws {
        let transport = WebDAVFixtureTransport([])
        let manager = DesktopWebDAVManager(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials(), transport: transport)
        let archive = try DesktopBackup.encode(DesktopBackupPayload(), password: "password")
        let task = Task { try await manager.push(data: archive) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled caller cannot initiate a new upload") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

private struct HangingWebDAVTransport: IOSWebDAVTransport {
    func send(_ request: URLRequest, body: Data?) async throws -> (HTTPURLResponse, Data) {
        try await Task.sleep(for: .seconds(30))
        return (HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data())
    }
}

private final class WebDAVFixtureTransport: IOSWebDAVTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]
        init(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) { self.status = status; self.body = body; self.headers = headers }
    }
    private let lock = NSLock()
    private var queue: [Response]
    private var capturedRequests: [URLRequest] = []
    private var capturedBodies: [Data?] = []
    var requests: [URLRequest] { lock.withLock { capturedRequests } }
    var bodies: [Data?] { lock.withLock { capturedBodies } }
    init(_ responses: [Response]) { queue = responses }
    func send(_ request: URLRequest, body: Data?) async throws -> (HTTPURLResponse, Data) {
        let response = try lock.withLock {
            guard !queue.isEmpty else { throw IOSSyncBackupError.remoteProviderUnavailable("Fixture exhausted") }
            capturedRequests.append(request); capturedBodies.append(body)
            return queue.removeFirst()
        }
        return (HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!, response.body)
    }
}
