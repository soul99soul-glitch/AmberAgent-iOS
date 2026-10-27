import CommonCrypto
import CryptoKit
import XCTest
@testable import AmberMac

@MainActor final class DesktopIOSBackupTests: XCTestCase {
    private static let gif = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    func testImportCreatesNewConversationCopiesWithMessagesAndImages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = [UUID(), UUID()]
        let archive = try makeArchive(conversations: [
            document(id: ids[0], title: "iOS one", user: "hello from iPhone", assistant: "hi there", image: Self.gif),
            document(id: ids[1], title: "iOS two", user: "second question", assistant: "second answer"),
        ], passphrase: "secret")
        let storage = DesktopKMPConversationStorage(directory: directory.appendingPathComponent("conversations"))
        let result = try await coordinator(storage, directory: directory)
            .restore(DesktopIOSBackup.payload(archive, passphrase: "secret"))
        XCTAssertEqual(result.conversations.count, 2)
        XCTAssertNil(result.knowledgeConversationID)
        XCTAssertEqual(result.providerCount, 0)
        let saved = try await storage.loadAll()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(Set(saved.map(\.id)).isDisjoint(with: ids))
        let first = try XCTUnwrap(saved.first { $0.title == "iOS one" })
        XCTAssertEqual(first.messages.map(\.text), ["hello from iPhone", "hi there"])
        XCTAssertEqual(first.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(first.messages[0].images.map(\.url), [Self.gif])
        let second = try XCTUnwrap(saved.first { $0.title == "iOS two" })
        XCTAssertEqual(second.messages.map(\.text), ["second question", "second answer"])
    }

    func testWrongMissingPassphraseAndEmptyPassphraseArchive() throws {
        let doc = document(id: UUID(), title: "t", user: "u", assistant: "a")
        let locked = try makeArchive(conversations: [doc], passphrase: "secret")
        XCTAssertThrowsError(try DesktopIOSBackup.payload(locked, passphrase: "wrong")) {
            XCTAssertTrue($0.localizedDescription.contains("密码错误"))
        }
        XCTAssertThrowsError(try DesktopIOSBackup.payload(locked, passphrase: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("请先填写备份密码"))
        }
        XCTAssertEqual(try DesktopIOSBackup.payload(locked, passphrase: "  secret ").conversations.count, 1)
        let open = try makeArchive(conversations: [doc, document(id: UUID(), title: "t2", user: "u", assistant: "a")], passphrase: nil)
        XCTAssertEqual(try DesktopIOSBackup.payload(open, passphrase: nil).conversations.count, 2)
        XCTAssertEqual(try DesktopIOSBackup.payload(open, passphrase: "ignored").conversations.count, 2)
    }

    func testUnsupportedVersionAndCorruptArchivesAreRejected() throws {
        let doc = document(id: UUID(), title: "t", user: "u", assistant: "a")
        XCTAssertThrowsError(try DesktopIOSBackup.payload(makeArchive(conversations: [doc], passphrase: nil, version: 2), passphrase: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("不支持的 iOS 备份版本"))
        }
        XCTAssertThrowsError(try DesktopIOSBackup.payload(makeArchive(conversations: [doc], passphrase: nil, tamper: true), passphrase: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("已损坏"))
        }
        XCTAssertThrowsError(try DesktopIOSBackup.payload(Data("not a zip".utf8), passphrase: nil))
    }

    // MARK: - Fixture: same algorithm as IOSSyncBackup.export

    private func document(id: UUID, title: String, user: String, assistant: String, image: String? = nil) -> String {
        func message(_ role: String, _ text: String, image: String?) -> [String: Any] {
            var parts: [[String: Any]] = [["type": "text", "text": text]]
            if let image { parts.append(["type": "image", "url": image]) }
            return ["id": UUID().uuidString.lowercased(), "role": role, "parts": parts, "annotations": [],
                    "createdAt": "2026-10-23T16:09:10.123456789"]
        }
        let object: [String: Any] = [
            "id": id.uuidString.lowercased(), "assistantId": UUID().uuidString.lowercased(), "title": title,
            "messageNodes": [message("user", user, image: image), message("assistant", assistant, image: nil)].map {
                ["id": UUID().uuidString.lowercased(), "messages": [$0], "selectIndex": 0]
            },
            "createAt": "2026-10-23T08:09:10.123456789Z", "updateAt": "2026-10-23T08:09:10.123456789Z",
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func makeArchive(conversations: [String], passphrase: String?, version: Int = 1, tamper: Bool = false) throws -> Data {
        var conversationEntries: [(String, Data)] = [("index.json", Data("[]".utf8))]
        for doc in conversations {
            let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(doc.utf8)) as? [String: Any])?["id"] as? String)
            conversationEntries.append(("\(id).json", Data(doc.utf8)))
        }
        let payloadZip = storedZip([
            ("settings.json", Data(#"{"providers":[]}"#.utf8)),
            ("conversations.zip", storedZip(conversationEntries)),
            ("payload_manifest.json", Data(#"{"datasets":[]}"#.utf8)),
        ])
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let box = try AES.GCM.seal(payloadZip, using: key(trimmed.isEmpty ? "AmberAgent-NoPassphrase-v1" : trimmed, salt: salt),
            nonce: AES.GCM.Nonce(data: iv))
        var encrypted = box.ciphertext + box.tag
        let sha = SHA256.hash(data: encrypted).map { String(format: "%02x", $0) }.joined()
        if tamper { encrypted[encrypted.startIndex] ^= 0xff }
        let manifest: [String: Any] = [
            "archiveVersion": version, "appVersionName": "1.0", "appVersionCode": 1, "createdAt": 0,
            "deviceId": "device", "deviceLabel": "iOS iPhone", "mode": "MANUAL", "remoteRevision": "", "encrypted": true,
            "kdf": ["name": "PBKDF2WithHmacSHA256", "iterations": 210_000, "saltBase64": salt.base64EncodedString(), "keySizeBits": 256],
            "cipher": ["name": "AES/GCM/NoPadding", "ivBase64": iv.base64EncodedString(), "tagSizeBits": 128],
            "payloadSha256": sha, "passphraseProtected": !trimmed.isEmpty,
        ]
        return storedZip([("manifest.json", try JSONSerialization.data(withJSONObject: manifest)), ("payload.enc", encrypted)])
    }

    private func key(_ password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var output = Data(repeating: 0, count: 32)
        _ = output.withUnsafeMutableBytes { bytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000,
                        bytes.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        return SymmetricKey(data: output)
    }

    /// Stored (method 0) zip matching IOSStoredZipArchive.Writer; CRC is unchecked by readers so it is left 0.
    private func storedZip(_ entries: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func u32(_ v: Int, _ d: inout Data) { u16(v & 0xffff, &d); u16((v >> 16) & 0xffff, &d) }
        for (name, data) in entries {
            let nameData = Data(name.utf8), offset = output.count
            u32(0x04034b50, &output); u16(20, &output); u16(0x0800, &output); u16(0, &output); u16(0, &output); u16(0, &output)
            u32(0, &output); u32(data.count, &output); u32(data.count, &output); u16(nameData.count, &output); u16(0, &output)
            output.append(nameData); output.append(data)
            u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(data.count, &central); u32(data.count, &central)
            u16(nameData.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central); central.append(nameData)
        }
        let centralOffset = output.count
        output.append(central)
        u32(0x06054b50, &output); u16(0, &output); u16(0, &output); u16(entries.count, &output); u16(entries.count, &output)
        u32(central.count, &output); u32(centralOffset, &output); u16(0, &output)
        return output
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amber-ios-backup-" + UUID().uuidString, isDirectory: true)
    }

    private func coordinator(_ storage: any DesktopConversationStorage, directory: URL) -> DesktopBackupCoordinator {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.ios-backup.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        return DesktopBackupCoordinator(storage: storage, files: DesktopWorkspaceFiles(directory: directory.appendingPathComponent("files")),
            insights: DesktopConversationInsights(directory: directory.appendingPathComponent("insights")), settings: settings,
            knowledge: DesktopKnowledgeStore(directory: directory.appendingPathComponent("knowledge")))
    }
}
