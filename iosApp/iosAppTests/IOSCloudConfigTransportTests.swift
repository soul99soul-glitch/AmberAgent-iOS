import CryptoKit
import Foundation
import Security
import XCTest
@testable import iosApp

/// Wire-level tests for the cloud configuration transport
/// (docs/architecture/cloud-configuration-api.md): RFC7638 kid math, SPKI↔JWK
/// binding, compact JWE sealing, kid pinning, typed error mapping and requestId
/// idempotency. Self-generated RSA-3072 test keys only — never real credentials.
final class IOSCloudConfigTransportTests: XCTestCase {

    // MARK: - Envelope verification

    func testVerifyRecomputesRfc7638KidAndBindsSpkiToJwk() throws {
        let key = try TestRSAKey()
        let dto = try key.importKeyDTO(gatewayId: "gw", deviceId: "dev-1", kid: key.kid)

        let verified = try IOSCloudConfigEnvelope.verify(dto, gatewayId: "gw")

        XCTAssertEqual(verified.kid, key.kid)
        XCTAssertEqual(verified.deviceId, "dev-1")
        XCTAssertEqual(verified.serverTime, dto.serverTime)
        XCTAssertTrue(SecKeyIsAlgorithmSupported(verified.secKey, .encrypt, .rsaEncryptionOAEPSHA256))
    }

    func testVerifyRejectsTamperedKidAndMismatchedGateway() throws {
        let key = try TestRSAKey()
        var dto = try key.importKeyDTO(gatewayId: "gw", deviceId: "dev-1", kid: "forged-kid")
        XCTAssertThrowsError(try IOSCloudConfigEnvelope.verify(dto, gatewayId: "gw")) {
            XCTAssertEqual($0 as? IOSCloudConfigError, .malformedResponse)
        }
        dto = try key.importKeyDTO(gatewayId: "other-gateway", deviceId: "dev-1", kid: key.kid)
        XCTAssertThrowsError(try IOSCloudConfigEnvelope.verify(dto, gatewayId: "gw"),
                             "payload 必须绑定当前 gatewayId")
    }

    func testSealProducesContractJweThatRoundTrips() throws {
        let key = try TestRSAKey()
        let verified = try IOSCloudConfigEnvelope.verify(
            key.importKeyDTO(gatewayId: "gw", deviceId: "dev-1", kid: key.kid), gatewayId: "gw")

        let plaintext = Data("{\"version\":1,\"secret\":\"fake-exa-key\"}".utf8)
        let compact = try IOSCloudConfigEnvelope.seal(payload: plaintext, key: verified)

        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 5, "compact JWE 必须是 protected.encryptedKey.iv.ciphertext.tag")
        let header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64urlEncoded: String(parts[0])))) as? [String: Any]
        )
        XCTAssertEqual(Set(header.keys), ["alg", "enc", "kid", "typ"], "protected header 只允许契约四键")
        XCTAssertEqual(header["alg"] as? String, "RSA-OAEP-256")
        XCTAssertEqual(header["enc"] as? String, "A256GCM")
        XCTAssertEqual(header["kid"] as? String, key.kid)
        XCTAssertEqual(header["typ"] as? String, "amber-config+jwe")

        // Round-trip proof the same operations Nimbus performs: unwrap the CEK
        // with the private key, then open A256GCM with the protected AAD.
        var failure: Unmanaged<CFError>?
        let wrapped = try XCTUnwrap(Data(base64urlEncoded: String(parts[1])))
        let cekData = try XCTUnwrap(
            SecKeyCreateDecryptedData(key.privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &failure) as Data?,
            "OAEP-256 解包失败：\(failure?.takeRetainedValue().localizedDescription ?? "")"
        )
        let nonce = try XCTUnwrap(Data(base64urlEncoded: String(parts[2])))
        let ciphertext = try XCTUnwrap(Data(base64urlEncoded: String(parts[3])))
        let tag = try XCTUnwrap(Data(base64urlEncoded: String(parts[4])))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: cekData), authenticating: Data(String(parts[0]).utf8))
        XCTAssertEqual(opened, plaintext, "A256GCM + protected-AAD 必须能还原原 payload")
    }

    // MARK: - Transport happy path

    func testApplyFetchesKeyPinsKidSealsAndPosts() async throws {
        let key = try TestRSAKey()
        let harness = Harness(
            importKeyJSON: key.importKeyJSON(gatewayId: "gw", deviceId: "dev-1"),
            viewJSON: viewJSON(revision: 99)
        )
        let clock = StepClock(start: key.serverTime, step: 10)
        let transport = IOSCloudConfigClient(
            client: harness.makeClient(), gatewayId: "gw",
            kidStore: harness.kidStore, now: { clock.next() }
        )
        let bundle = IOSCloudConfigBundle(
            model: .init(providerKind: "openai", modelId: "model-b", baseUrl: "https://b.example/v1",
                         credential: .replace("fake-model-key")),
            search: [.init(type: "exa", name: "Exa", enabled: true,
                           credential: .replace("fake-exa-key"), includeInConfiguration: true)],
            freeSources: ["duckduckgo"]
        )

        // The user reviewed revision 2; the transport must submit exactly that —
        // not a POST-time refetched value that would authorize a stale draft.
        let receipt = try await transport.applyCloudConfiguration(bundle, requestId: "req-1", expectedRevision: 2)

        XCTAssertEqual(receipt.requestId, "req-1")
        XCTAssertEqual(receipt.revision, 3)
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(harness.kidStore.load("gw"), key.kid, "首次获取后必须固定 kid")

        let capturedJWE = await harness.lastPostJWE
        let jwe = try XCTUnwrap(capturedJWE)
        let payload = try XCTUnwrap(try? harness.decryptPayload(jwe, key: key))
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["gatewayId"] as? String, "gw")
        XCTAssertEqual(payload["deviceId"] as? String, "dev-1")
        XCTAssertEqual(payload["requestId"] as? String, "req-1")
        XCTAssertEqual(payload["expectedRevision"] as? Int, 2,
                       "expectedRevision 必须是用户审过的 revision，而非 POST 前新拉到的 99")
        let configGets = await harness.configGetCount
        XCTAssertEqual(configGets, 0, "apply 不得在 POST 前重新拉 revision 给旧草稿授权")
        XCTAssertEqual(payload["issuedAt"] as? Int, Int(key.serverTime + 10),
                       "issuedAt 跟随服务端时钟加本地流逝")
        XCTAssertEqual(payload["expiresAt"] as? Int, Int(key.serverTime + 10 + 120))
        let configuration = try XCTUnwrap(payload["configuration"] as? [String: Any])
        let model = try XCTUnwrap(configuration["model"] as? [String: Any])
        XCTAssertEqual(model["provider"] as? String, "openai")
        XCTAssertEqual(model["modelId"] as? String, "model-b")
        let search = try XCTUnwrap(configuration["search"] as? [String: Any])
        XCTAssertEqual(search["sources"] as? [String], ["exa", "duckduckgo"])
        XCTAssertEqual(search["mode"] as? String, "fallback")
        let credentials = try XCTUnwrap(payload["credentials"] as? [String: Any])
        XCTAssertEqual((credentials["modelApiKey"] as? [String: Any])?["value"] as? String, "fake-model-key")
        XCTAssertEqual((credentials["exaApiKey"] as? [String: Any])?["value"] as? String, "fake-exa-key")
        XCTAssertNil(credentials["braveApiKey"])
        let wire = try XCTUnwrap(String(data: XCTUnwrap(jwe.data(using: .utf8)), encoding: .utf8))
        XCTAssertFalse(wire.contains("fake-model-key"), "JWE 内不得出现明文 Key")
    }

    func testApplyRetriesExpiredEnvelopeOnceWithSameRequestId() async throws {
        let key = try TestRSAKey()
        let harness = Harness(
            importKeyJSON: key.importKeyJSON(gatewayId: "gw", deviceId: "dev-1"),
            viewJSON: viewJSON(revision: 0),
            postResponses: [
                (410, #"{"error":"envelope_expired"}"#),
                (200, #"{"requestId":"req-2","revision":1,"currentRevision":1,"replayed":true,"effective":"next_task"}"#),
            ]
        )
        let transport = IOSCloudConfigClient(client: harness.makeClient(), gatewayId: "gw",
                                             kidStore: harness.kidStore, now: { key.serverTime })
        let receipt = try await transport.applyCloudConfiguration(
            IOSCloudConfigBundle(model: nil, search: [], freeSources: [], extraCredentials: ["exaApiKey": .delete]),
            requestId: "req-2", expectedRevision: 0
        )

        XCTAssertTrue(receipt.replayed, "410 后应同 requestId 重封重试一次")
        let postCount = await harness.postCount
        XCTAssertEqual(postCount, 2)
    }

    // MARK: - Error mapping

    func testRevisionConflictCarriesCurrentRevision() async throws {
        let key = try TestRSAKey()
        let harness = Harness(
            importKeyJSON: key.importKeyJSON(gatewayId: "gw", deviceId: "dev-1"),
            viewJSON: viewJSON(revision: 1),
            postResponses: [(409, #"{"error":"revision_conflict","currentRevision":7}"#)]
        )
        let transport = IOSCloudConfigClient(client: harness.makeClient(), gatewayId: "gw",
                                             kidStore: harness.kidStore, now: { key.serverTime })

        await assertThrows(
            try await transport.applyCloudConfiguration(
                IOSCloudConfigBundle(model: nil, search: [], freeSources: [],
                                     extraCredentials: ["exaApiKey": .replace("fake")]),
                requestId: "req-3", expectedRevision: 1
            )
        ) {
            XCTAssertEqual($0 as? IOSCloudConfigError, .revisionConflict(current: 7))
        }
    }

    func testCredentialActionRequiredAndNotFoundAndUntrustedMap() async throws {
        let key = try TestRSAKey()
        let harness = Harness(
            importKeyJSON: key.importKeyJSON(gatewayId: "gw", deviceId: "dev-1"),
            viewJSON: viewJSON(revision: 0),
            postResponses: [(422, #"{"error":"credential_action_required"}"#)]
        )
        let transport = IOSCloudConfigClient(client: harness.makeClient(), gatewayId: "gw",
                                             kidStore: harness.kidStore, now: { key.serverTime })

        await assertThrows(
            try await transport.applyCloudConfiguration(
                IOSCloudConfigBundle(model: .init(providerKind: "claude", modelId: "m", baseUrl: "", credential: .keep),
                                     search: [], freeSources: []),
                requestId: "req-4", expectedRevision: 0
            )
        ) { XCTAssertEqual($0 as? IOSCloudConfigError, .credentialActionRequired) }

        let missing = Harness(viewStatus: 404)
        let missingTransport = IOSCloudConfigClient(client: missing.makeClient(), gatewayId: "gw",
                                                    kidStore: missing.kidStore, now: { 0 })
        await assertThrows(try await missingTransport.fetchCloudConfiguration()) {
            XCTAssertEqual($0 as? IOSCloudConfigError, .notFound)
        }

        let denied = Harness(viewJSON: #"{"error":"untrusted_device"}"#, viewStatus: 403)
        let deniedTransport = IOSCloudConfigClient(client: denied.makeClient(), gatewayId: "gw",
                                                   kidStore: denied.kidStore, now: { 0 })
        await assertThrows(try await deniedTransport.fetchCloudConfiguration()) {
            XCTAssertEqual($0 as? IOSCloudConfigError, .untrustedDevice)
        }
    }

    func testChangedKidIsAHardStop() async throws {
        let keyA = try TestRSAKey()
        let keyB = try TestRSAKey()
        let kidStore = IOSCloudImportKidStore.ephemeral()
        kidStore.store("gw", keyA.kid)

        let harness = Harness(
            importKeyJSON: keyB.importKeyJSON(gatewayId: "gw", deviceId: "dev-1"),
            viewJSON: viewJSON(revision: 0)
        )
        let transport = IOSCloudConfigClient(client: harness.makeClient(), gatewayId: "gw",
                                             kidStore: kidStore, now: { keyB.serverTime })

        await assertThrows(
            try await transport.applyCloudConfiguration(
                IOSCloudConfigBundle(model: nil, search: [], freeSources: [],
                                     extraCredentials: ["exaApiKey": .replace("fake")]),
                requestId: "req-5", expectedRevision: 0
            )
        ) {
            XCTAssertEqual($0 as? IOSCloudConfigError, .importKeyChanged,
                           "kid 变化不得自动更新后继续发送")
        }
        let posted = await harness.postCount
        XCTAssertEqual(posted, 0, "信任未确认前不得发出 POST")
        XCTAssertEqual(kidStore.load("gw"), keyA.kid, "旧 pin 保持不变，由显式重置清除")
    }

    @MainActor
    func testStoreConfirmAfterConflictSubmitsAndUpdatesRemoteModelState() async throws {
        let key = try TestRSAKey()
        let gwId = "gw-\(UUID().uuidString)"
        defer { IOSCloudConfigClient.resetImportKeyTrust(gatewayId: gwId) }

        let updatedView = #"{"gatewayId":"\#(gwId)","revision":5,"model":{"provider":"openai","modelId":"deepseek-chat","baseUrl":"https://api.deepseek.com/v1"},"search":{"sources":["bing","exa"],"mode":"fallback"},"credentials":{"modelApiKey":{"configured":true},"exaApiKey":{"configured":true},"braveApiKey":{"configured":false}},"supportedModelProviders":["openai","claude"],"supportedSearchSources":["bing","duckduckgo","exa","brave"]}"#
        let harness = Harness(
            importKeyJSON: key.importKeyJSON(gatewayId: gwId, deviceId: "dev-1"),
            viewJSON: updatedView,
            postResponses: [
                (409, #"{"error":"revision_conflict","currentRevision":4}"#),
                (200, #"{"requestId":"req-ok","revision":5,"currentRevision":5,"replayed":false,"effective":"next_task"}"#)
            ]
        )

        let suiteName = "CloudConfigStoreTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(
            connection: MacGatewayConnection(
                gatewayId: gwId, name: "Cloud", addrs: ["127.0.0.1"],
                port: 1, fingerprint: "", deviceId: "dev-1"
            ),
            client: harness.makeClient()
        )

        let bundle = IOSCloudConfigBundle(
            model: .init(
                providerKind: "openai",
                modelId: "deepseek-chat",
                baseUrl: "https://api.deepseek.com/v1",
                credential: .replace("sk-deepseek-long-key")
            ),
            search: [],
            freeSources: []
        )

        // 第一次提交遇到并发版本冲突（409）：返回明确错误并自动刷新 store.cloudConfig
        let conflictError = await store.applyCloudBundle(bundle, expectedRevision: 3)
        XCTAssertNotNil(conflictError)
        XCTAssertEqual(store.cloudConfig?.revision, 5, "冲突后应自动刷新最新云端配置")

        // 用户确认最新云端版本后再次提交：提交成功，更新当前状态与成功反馈
        let secondError = await store.applyCloudBundle(bundle, expectedRevision: store.cloudConfig?.revision)
        XCTAssertNil(secondError)
        XCTAssertEqual(store.cloudConfig?.model?.provider, "openai")
        XCTAssertEqual(store.cloudConfig?.model?.modelId, "deepseek-chat")
        XCTAssertEqual(store.cloudConfig?.model?.baseUrl, "https://api.deepseek.com/v1")
        XCTAssertEqual(store.cloudConfig?.model?.keyConfigured, true)
        XCTAssertEqual(store.notice?.isError, false)
        XCTAssertTrue(store.notice?.text.contains("deepseek-chat") == true)
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expression: @autoclosure () async throws -> some Any,
        _ check: (Error) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("应当抛出错误", file: file, line: line)
        } catch {
            check(error)
        }
    }

    private func viewJSON(revision: Int) -> String {
        #"{"gatewayId":"gw","revision":\#(revision),"model":{"provider":"openai","modelId":"old","baseUrl":"https://a.example"},"search":{"sources":["bing"],"mode":"fallback"},"credentials":{"modelApiKey":{"configured":true},"exaApiKey":{"configured":true},"braveApiKey":{"configured":false}},"supportedModelProviders":["openai","claude"],"supportedSearchSources":["bing","duckduckgo","exa","brave"]}"#
    }

    /// Fake HTTP layer on `MacGatewayClient.transport`: answers the three
    /// contract endpoints from canned JSON and captures the sealed POST body.
    private actor Harness {
        nonisolated let kidStore = IOSCloudImportKidStore.ephemeral()
        private(set) var lastPostJWE: String?
        private(set) var postCount = 0
        private(set) var configGetCount = 0
        private var postResponses: [(Int, String)]

        private let cannedImportKey: String
        private let cannedView: String
        private let cannedViewStatus: Int

        init(importKeyJSON: String = "", viewJSON: String = "", viewStatus: Int = 200,
             postResponses: [(Int, String)] = [(200, #"{"requestId":"req-1","revision":3,"currentRevision":3,"replayed":false,"effective":"next_task"}"#)]) {
            self.postResponses = postResponses
            self.cannedImportKey = importKeyJSON
            self.cannedView = viewJSON
            self.cannedViewStatus = viewStatus
        }

        /// Actor references are Sendable, so the injected transport can hop
        /// back onto `respond(to:)` without any unsafe boxing.
        nonisolated func makeClient() -> MacGatewayClient {
            MacGatewayClient(addrs: ["127.0.0.1"], port: 1, fingerprint: "", token: "tok") { [self] request, _ in
                await self.respond(to: request)
            }
        }

        func respond(to request: URLRequest) -> (Data, URLResponse) {
            let path = request.url?.path ?? ""
            let status: Int
            let body: String
            switch (request.httpMethod, path) {
            case ("GET", "/v2/configuration"):
                configGetCount += 1
                (status, body) = (cannedViewStatus, cannedView)
            case ("GET", "/v2/configuration/import-key"):
                (status, body) = (200, cannedImportKey)
            case ("POST", "/v2/configuration"):
                if let data = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lastPostJWE = json["jwe"] as? String
                }
                postCount += 1
                (status, body) = postResponses.isEmpty
                    ? (200, #"{"requestId":"x","revision":1,"currentRevision":1,"replayed":false,"effective":"next_task"}"#)
                    : postResponses.removeFirst()
            default:
                (status, body) = (404, #"{"error":"not_found"}"#)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        /// Repeats the server's side of the envelope for assertions: unwrap CEK
        /// with the test private key, open A256GCM with the protected AAD.
        nonisolated func decryptPayload(_ jwe: String, key: TestRSAKey) throws -> [String: Any]? {
            let parts = jwe.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5,
                  let wrapped = Data(base64urlEncoded: parts[1]),
                  let nonce = Data(base64urlEncoded: parts[2]),
                  let ciphertext = Data(base64urlEncoded: parts[3]),
                  let tag = Data(base64urlEncoded: parts[4]),
                  let cek = SecKeyCreateDecryptedData(key.privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, nil) as Data?,
                  let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag),
                  let opened = try? AES.GCM.open(box, using: SymmetricKey(data: cek), authenticating: Data(parts[0].utf8))
            else { return nil }
            return try JSONSerialization.jsonObject(with: opened) as? [String: Any]
        }
    }
}

/// Advances `step` seconds per `next()` call so tests can model local elapsed
/// time between the import-key fetch and the envelope seal.
private final class StepClock: @unchecked Sendable {
    private var value: Int64
    private let step: Int64
    init(start: Int64, step: Int64) { value = start; self.step = step }
    func next() -> Int64 { defer { value += step }; return value }
}

/// Self-generated RSA-3072 pair plus the contract's import-key JSON built from
/// its public numbers — JWK n/e, RFC7638 kid and a real X.509 SPKI DER.
private struct TestRSAKey: @unchecked Sendable {
    let privateKey: SecKey
    let pkcs1: Data
    let modulus: Data
    let exponent: Data
    let kid: String
    let serverTime: Int64

    init() throws {
        var failure: Unmanaged<CFError>?
        privateKey = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072,
            kSecAttrIsPermanent as String: false,
        ] as CFDictionary, &failure), "测试 RSA 密钥生成失败")
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        var offset = 0
        let sequence = try Self.derValue(Array(pkcs1), &offset, tag: 0x30)
        var inner = 0
        func unsigned(_ bytes: [UInt8]) -> Data { Data(bytes.drop(while: { $0 == 0 })) }
        modulus = unsigned(try Self.derValue(sequence, &inner, tag: 0x02))
        exponent = unsigned(try Self.derValue(sequence, &inner, tag: 0x02))
        kid = try XCTUnwrap(IOSCloudConfigEnvelope.jwkThumbprint(
            e: IOSCloudConfigEnvelope.base64url(exponent),
            n: IOSCloudConfigEnvelope.base64url(modulus)
        ))
        serverTime = 1_799_999_000
    }

    /// X.509 SubjectPublicKeyInfo: SEQ{ SEQ{OID rsaEncryption, NULL}, BIT STRING{PKCS1} }.
    var spkiDer: Data {
        let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let algorithm = Self.tlv(0x30, Self.tlv(0x06, Data(rsaOID)) + Self.tlv(0x05, Data()))
        let bits = Self.tlv(0x03, Data([0x00]) + pkcs1)
        return Self.tlv(0x30, algorithm + bits)
    }

    func importKeyDTO(gatewayId: String, deviceId: String, kid: String) throws -> IOSCloudImportKeyDTO {
        let json = importKeyJSON(gatewayId: gatewayId, deviceId: deviceId, kid: kid)
        return try XCTUnwrap(try? JSONDecoder().decode(IOSCloudImportKeyDTO.self, from: Data(json.utf8)))
    }

    func importKeyJSON(gatewayId: String, deviceId: String, kid: String? = nil) -> String {
        let n = IOSCloudConfigEnvelope.base64url(modulus)
        let e = IOSCloudConfigEnvelope.base64url(exponent)
        return """
        {"version":1,"gatewayId":"\(gatewayId)","deviceId":"\(deviceId)","kid":"\(kid ?? self.kid)",\
        "alg":"RSA-OAEP-256","enc":"A256GCM","publicJwk":{"kty":"RSA","kid":"\(kid ?? self.kid)",\
        "alg":"RSA-OAEP-256","use":"enc","n":"\(n)","e":"\(e)"},\
        "publicKeySpkiDerBase64":"\(spkiDer.base64EncodedString())","serverTime":\(serverTime),\
        "maxEnvelopeLifetimeSeconds":300}
        """
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        if content.count < 128 {
            data.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(content)
        return data
    }

    private static func derValue(_ bytes: [UInt8], _ offset: inout Int, tag: UInt8) throws -> [UInt8] {
        struct DerError: Error {}
        guard offset < bytes.count, bytes[offset] == tag else { throw DerError() }
        offset += 1
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
            let count = length & 127; length = 0
            for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
        }
        guard offset + length <= bytes.count else { throw DerError() }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }
}

private extension Data {
    init?(base64urlEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
