import Foundation
@preconcurrency import Shared

enum IOSConversationThreadEdgeValidationError: LocalizedError, Equatable {
    case invalidConversationID(String)
    case conversationNotInBackup(String)
    case duplicateChild(String)
    case cycle(String)

    var errorDescription: String? {
        switch self {
        case .invalidConversationID(let id):
            return "线程关系包含无效会话 ID：\(id)"
        case .conversationNotInBackup(let id):
            return "线程关系指向未恢复的会话：\(id)"
        case .duplicateChild(let id):
            return "线程关系包含重复 child：\(id)"
        case .cycle(let id):
            return "线程关系包含循环：\(id)"
        }
    }
}

/// Codable backup representation of the Room `thread_edge` row.
struct IOSConversationThreadEdge: Codable, Equatable, Sendable {
    let childThreadId: String
    let parentThreadId: String
    let agentPath: String
    let nickname: String?
    let roleAssistantId: String?
    let forkTurns: String
    let status: String
    let createdAt: Int64

    /// Validate and canonicalize relations against the conversation documents
    /// restored in the same archive. Missing parents belong to retained archive
    /// records. Check the merged tree so imported edges cannot create a cycle
    /// through an existing local relationship.
    static func validated(
        _ edges: [Self],
        documentIDs: Set<String>,
        existingEdges: [Self] = []
    ) throws -> [Self] {
        var normalizedDocumentIDs = Set<String>()
        for documentID in documentIDs {
            normalizedDocumentIDs.insert(try canonicalID(documentID))
        }
        var children = Set<String>()
        var parentByChild = Dictionary(existingEdges.map {
            ($0.childThreadId.lowercased(), $0.parentThreadId.lowercased())
        }, uniquingKeysWith: { _, latest in latest })
        var normalized: [Self] = []

        for edge in edges {
            let child = try canonicalID(edge.childThreadId)
            let parent = try canonicalID(edge.parentThreadId)
            guard normalizedDocumentIDs.contains(child) else {
                throw IOSConversationThreadEdgeValidationError.conversationNotInBackup(child)
            }
            guard child != parent else {
                throw IOSConversationThreadEdgeValidationError.cycle(child)
            }
            guard children.insert(child).inserted else {
                throw IOSConversationThreadEdgeValidationError.duplicateChild(child)
            }
            parentByChild[child] = parent
            normalized.append(Self(
                childThreadId: child,
                parentThreadId: parent,
                agentPath: edge.agentPath,
                nickname: edge.nickname,
                roleAssistantId: edge.roleAssistantId,
                forkTurns: edge.forkTurns,
                status: edge.status,
                createdAt: edge.createdAt
            ))
        }

        for start in normalized.map(\.childThreadId) {
            var seen: Set<String> = [start]
            var current = start
            while let parent = parentByChild[current] {
                guard seen.insert(parent).inserted else {
                    throw IOSConversationThreadEdgeValidationError.cycle(parent)
                }
                current = parent
            }
        }
        return normalized
    }

    private static func canonicalID(_ raw: String) throws -> String {
        guard let uuid = UUID(uuidString: raw) else {
            throw IOSConversationThreadEdgeValidationError.invalidConversationID(raw)
        }
        return uuid.uuidString.lowercased()
    }
}

extension IOSConversationThreadEdge {
    init(entity: ThreadEdgeEntity) {
        childThreadId = entity.childThreadId
        parentThreadId = entity.parentThreadId
        agentPath = entity.agentPath
        nickname = entity.nickname
        roleAssistantId = entity.roleAssistantId
        forkTurns = entity.forkTurns
        status = entity.status
        createdAt = entity.createdAt
    }

    func toEntity() -> ThreadEdgeEntity {
        ThreadEdgeEntity(
            childThreadId: childThreadId,
            parentThreadId: parentThreadId,
            agentPath: agentPath,
            nickname: nickname,
            roleAssistantId: roleAssistantId,
            forkTurns: forkTurns,
            status: status,
            createdAt: createdAt
        )
    }

}
