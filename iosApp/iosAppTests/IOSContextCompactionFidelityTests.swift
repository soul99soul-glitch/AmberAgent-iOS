import XCTest
@preconcurrency import Shared
@testable import iosApp

/// I2.2 的 12 类 needle 基线：每类一个高置信实体，逐类缺失都必须被闸门判 0；
/// 全量存在时摘要通过，并把 must_not_lose 写进 compact payload。
@MainActor
final class IOSContextCompactionFidelityTests: XCTestCase {

    private let needles: [(kind: IOSHandoffEntityKind, value: String)] = [
        (.file, "Sources/Amber/ContextCoordinator.swift"),
        (.command, "xcodebuild -scheme iosApp test"),
        (.error, "error: cannot find 'Foo' in scope"),
        (.exitCode, "exit code 65"),
        (.date, "2026-10-31"),
        (.number, "85%"),
        (.url, "https://example.com/spec"),
        (.commit, "a1b2c3d4"),
        (.constraint, "必须保持原始 transcript 不变"),
        (.approval, "允许修改 Settings.swift"),
        (.rejected, "不要用 pnpm"),
        (.decision, "决定采用单阈值"),
    ]

    private var source: [UIMessage] {
        let user = UIMessage.companion.user(prompt: """
        请按 2026-10-31 的 spec 实现，目标 85%
        必须保持原始 transcript 不变
        允许修改 Settings.swift
        不要用 pnpm
        决定采用单阈值
        参考 https://example.com/spec 和提交 a1b2c3d4
        """)
        let tool = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: "call-1",
                    toolName: "terminal_execute",
                    input: #"{"command":"xcodebuild -scheme iosApp test"}"#,
                    output: [UIMessagePart.Text(text: """
                    Sources/Amber/ContextCoordinator.swift
                    error: cannot find 'Foo' in scope
                    exit code 65
                    """, metadata: nil)],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 10, day: 31, hour: 12, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        return [user, tool]
    }

    private var handoff: String {
        """
        # Goal
        完成上下文压缩保真闸门，让下一个模型拿到可继续执行的事实；这段说明本身用于满足
        摘要的最低长度与结构要求，不承载任何额外事实。
        # Constraints
        必须保持原始 transcript 不变
        不要用 pnpm
        决定采用单阈值
        允许修改 Settings.swift
        # Progress
        参考 https://example.com/spec 与提交 a1b2c3d4，日期 2026-10-31，目标 85%。
        # Evidence
        Sources/Amber/ContextCoordinator.swift
        xcodebuild -scheme iosApp test
        error: cannot find 'Foo' in scope
        exit code 65
        # Next Steps
        继续执行当前任务。
        """
    }

    func testExtractsEveryNeedleClass() {
        let entities = IOSContextCompactionFidelity.extract(from: source)
        XCTAssertEqual(
            Set(entities.map(\.kind)),
            Set(IOSHandoffEntityKind.allCases),
            "12 类必须都被提取：\(entities.map { "\($0.kind.rawValue)=\($0.value)" })"
        )
        for needle in needles {
            XCTAssertTrue(
                entities.contains { $0.kind == needle.kind && $0.value == needle.value },
                "缺少 \(needle.kind.rawValue): \(needle.value)"
            )
        }
    }

    func testEveryClassMissingIndependentlyScoresZero() {
        let entities = IOSContextCompactionFidelity.extract(from: source)
        XCTAssertTrue(IOSContextCompactionFidelity.missing(entities, in: handoff).isEmpty)

        for needle in needles {
            let broken = handoff.replacingOccurrences(of: needle.value, with: "[omitted]")
            let missing = IOSContextCompactionFidelity.missing(entities, in: broken)
            XCTAssertEqual(
                Set(missing.map(\.kind)),
                [needle.kind],
                "只应命中被删掉的 \(needle.kind.rawValue)，实际 \(missing.map { "\($0.kind.rawValue)=\($0.value)" })"
            )
        }
    }

    func testNormalizedPayloadRejectsDroppedNeedleAndStoresSurvivors() throws {
        let entities = IOSContextCompactionFidelity.extract(from: source)
        let full = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "timeline_summary": "The conversation compacts with all critical facts preserved.",
            "handoff_markdown": handoff,
            "covered_compact_ids": []
        ] as [String: Any])
        let accepted = IOSContextCompactionCoordinator.normalizedPayload(
            String(decoding: full, as: UTF8.self),
            sourceMessageIds: ["m1"], offeredCompactIds: [], createdAt: 1,
            mustNotLose: entities
        )
        let payload = try XCTUnwrap(accepted)
        XCTAssertTrue(payload.contains(#""must_not_lose""#))
        XCTAssertTrue(payload.contains(needles[0].value))

        let dropped = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "timeline_summary": "The conversation compacts with all critical facts preserved.",
            "handoff_markdown": handoff.replacingOccurrences(of: needles[5].value, with: "[omitted]"),
            "covered_compact_ids": []
        ] as [String: Any])
        XCTAssertNil(IOSContextCompactionCoordinator.normalizedPayload(
            String(decoding: dropped, as: UTF8.self),
            sourceMessageIds: ["m1"], offeredCompactIds: [], createdAt: 1,
            mustNotLose: entities
        ), "缺少 85% 这类关键数字时不得保存摘要")
    }

    func testWithoutEntitiesTheLegacyGateIsUnchanged() {
        XCTAssertTrue(IOSContextCompactionFidelity.extract(from: [
            UIMessage.companion.user(prompt: "继续")
        ]).isEmpty)
        XCTAssertTrue(IOSContextCompactionFidelity.missing([], in: "anything").isEmpty)
    }

    func testCredentialsRedactedBeforeExtractionAndInCompactedPayload() throws {
        let secretKey = "sk-proj-superSecretCompactionKey1234567890"
        let secretUrl = "https://example.com/oauth?api_key=my_secret_query_key_12345&state=ok"
        let msg = UIMessage.companion.user(prompt: """
        请修改 Sources/Amber/ContextCoordinator.swift
        使用密钥 \(secretKey) 访问 \(secretUrl)
        """)
        let entities = IOSContextCompactionFidelity.extract(from: [msg])
        for entity in entities {
            XCTAssertFalse(entity.value.contains(secretKey), "must_not_lose must not retain raw sk- key: \(entity)")
            XCTAssertFalse(entity.value.contains("my_secret_query_key_12345"), "must_not_lose must not retain raw query key: \(entity)")
        }

        let rawModelHandoff = """
        # Goal
        完成 Sources/Amber/ContextCoordinator.swift 的配置接入，保持上下文连续性并验证所有关键路径。
        # Progress
        已接入 \(secretUrl) 与密钥 \(secretKey)，正在等待下一步验证测试结果以确保无回归问题。
        # Next Steps
        继续跑测试。
        """
        let rawJSON = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "timeline_summary": "Connected using \(secretKey) and \(secretUrl).",
            "handoff_markdown": rawModelHandoff,
            "covered_compact_ids": []
        ] as [String: Any])
        let normalized = try XCTUnwrap(
            IOSContextCompactionCoordinator.normalizedPayload(
                String(decoding: rawJSON, as: UTF8.self),
                sourceMessageIds: ["m1"],
                offeredCompactIds: [],
                createdAt: 1,
                mustNotLose: entities
            )
        )
        XCTAssertFalse(normalized.contains(secretKey))
        XCTAssertFalse(normalized.contains("my_secret_query_key_12345"))
        XCTAssertTrue(normalized.contains("[REDACTED]"))
    }

    func testHardAnchorsValidatedAfterTruncationWhileSoftEntitiesDoNotReject() throws {
        let entities: [IOSHandoffEntity] = [
            IOSHandoffEntity(kind: .file, value: "Sources/Amber/ContextCoordinator.swift"),
            IOSHandoffEntity(kind: .constraint, value: "必须保持原始 transcript 完全不变且不修改旧消息"),
        ]
        // Soft constraint omitted -> still accepted because hard anchor (.file) is present.
        let handoffWithParaphrasedConstraint = """
        # Goal
        完成上下文压缩保真校验，保证关键结构化锚点不丢失，自然语言约束允许被模型同义改写。
        # Constraints
        保持原始记录不改动。
        # Relevant Files
        Sources/Amber/ContextCoordinator.swift
        """
        let rawJSON = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "timeline_summary": "Completed fidelity gate adjustment.",
            "handoff_markdown": handoffWithParaphrasedConstraint,
            "covered_compact_ids": []
        ] as [String: Any])
        XCTAssertNotNil(
            IOSContextCompactionCoordinator.normalizedPayload(
                String(decoding: rawJSON, as: UTF8.self),
                sourceMessageIds: ["m1"],
                offeredCompactIds: [],
                createdAt: 1,
                mustNotLose: entities
            ),
            "Paraphrased soft entity must not reject a handoff that keeps all hard anchors"
        )

        // Hard anchor placed past maxHandoffChars (24_000) -> truncated away -> must be rejected!
        let padded = "# Goal\n" + String(repeating: "a", count: IOSContextCompactionCoordinator.maxHandoffChars + 100) + "\n# Relevant Files\nSources/Amber/ContextCoordinator.swift"
        let truncatedJSON = try JSONSerialization.data(withJSONObject: [
            "schema_version": 2,
            "timeline_summary": "Completed fidelity gate adjustment.",
            "handoff_markdown": padded,
            "covered_compact_ids": []
        ] as [String: Any])
        XCTAssertNil(
            IOSContextCompactionCoordinator.normalizedPayload(
                String(decoding: truncatedJSON, as: UTF8.self),
                sourceMessageIds: ["m1"],
                offeredCompactIds: [],
                createdAt: 1,
                mustNotLose: entities
            ),
            "Hard anchor lost after maxHandoffChars truncation must be rejected"
        )
    }
}
