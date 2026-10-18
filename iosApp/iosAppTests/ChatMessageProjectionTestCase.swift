import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
class ChatMessageProjectionTestCase: XCTestCase {
    func source(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosAppRoot = testsDir.deletingLastPathComponent()
        return try String(
            contentsOf: iosAppRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    static func astNodes(for markdown: String) -> [PackedAstNode] {
        guard let data = MarkdownBridge.parse(markdown),
              let reader = PackedAstReader(data: data),
              let root = reader.root() else {
            return []
        }
        return root.children
    }

    static func firstNode(ofType type: NodeType, in nodes: [PackedAstNode]) -> PackedAstNode? {
        for node in nodes {
            if node.type == type {
                return node
            }
            if let found = firstNode(ofType: type, in: node.children) {
                return found
            }
        }
        return nil
    }

    static func slice(_ source: String, node: PackedAstNode) -> String {
        guard node.startOffset < node.endOffset else { return "" }
        guard let startIndex = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: node.startOffset,
            limitedBy: source.utf8.endIndex
        ), let endIndex = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: node.endOffset,
            limitedBy: source.utf8.endIndex
        ) else {
            return ""
        }
        return String(source[startIndex..<endIndex])
    }
}
