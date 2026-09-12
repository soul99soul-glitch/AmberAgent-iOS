import XCTest
@testable import iosApp

final class IOSSSHOutputRedactorTests: XCTestCase {
    func testPasswordSplitAcrossChunksIsRedactedWithoutCrossChannelCarry() {
        let redactor = IOSSSHOutputRedactor(credential: .password("s3cret"))

        XCTAssertEqual(
            redactor.redact(IOSSSHOutputChunk(text: "before s3", isStderr: false))?.text,
            "before "
        )
        XCTAssertNil(redactor.redact(IOSSSHOutputChunk(text: "s3", isStderr: true)))

        let second = redactor.redact(IOSSSHOutputChunk(text: "cret after", isStderr: false))
        XCTAssertEqual(second?.text, "[redacted] after")

        let flushed = redactor.finish()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first?.isStderr, true)
        XCTAssertEqual(flushed.first?.text, "s3")
    }

    func testPrivateKeyPEMIsRedactedWhenBeginBodyAndEndSplitAcrossChunks() {
        let redactor = IOSSSHOutputRedactor(credential: .password("unused"))
        let chunks = [
            IOSSSHOutputChunk(text: "prefix\n-----BEGIN OPENSSH ", isStderr: false),
            IOSSSHOutputChunk(text: "PRIVATE KEY-----\nbase64-", isStderr: false),
            IOSSSHOutputChunk(text: "secret\n-----END OPENSSH PRIVATE ", isStderr: false),
            IOSSSHOutputChunk(text: "KEY-----\nsuffix", isStderr: false),
        ]

        let output = chunks.compactMap { redactor.redact($0)?.text }.joined()
            + redactor.finish().map(\.text).joined()

        XCTAssertEqual(output, "prefix\n[redacted]\nsuffix")
        XCTAssertFalse(output.contains("BEGIN"))
        XCTAssertFalse(output.contains("base64-secret"))
        XCTAssertFalse(output.contains("END"))
    }

    func testIncompletePrivateKeyAtFinishIsDiscarded() {
        let redactor = IOSSSHOutputRedactor(credential: .privateKey("not-used"))
        let first = redactor.redact(IOSSSHOutputChunk(
            text: "safe -----BEGIN EC PRIVATE KEY-----\nMIIE...",
            isStderr: true
        ))
        XCTAssertEqual(first?.text, "safe [redacted]")

        let flushed = redactor.finish()
        XCTAssertTrue(flushed.isEmpty)
    }

    func testStaticRedactionCoversFinalResultAndCredentialValue() {
        let password = IOSSSHOutputRedactor.redact(
            "failed password=s3cret and s3cret",
            credential: .password("s3cret")
        )
        XCTAssertEqual(password, "failed password=[redacted] and [redacted]")

        let pem = "-----BEGIN PRIVATE KEY-----\nsecret-body\n-----END PRIVATE KEY-----"
        XCTAssertEqual(
            IOSSSHOutputRedactor.redact(pem, credential: .privateKey(pem)),
            "[redacted]"
        )
    }
}
