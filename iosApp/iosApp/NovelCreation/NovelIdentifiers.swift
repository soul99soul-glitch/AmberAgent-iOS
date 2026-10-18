import Foundation

struct NovelIdentifier<Tag: Sendable>: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString.lowercased() }
}

enum NovelProjectIDTag: Sendable {}
enum NovelBranchIDTag: Sendable {}
enum NovelSessionIDTag: Sendable {}
enum NovelMessageIDTag: Sendable {}
enum NovelCandidateIDTag: Sendable {}
enum NovelChapterIDTag: Sendable {}
enum NovelChapterVersionIDTag: Sendable {}
enum NovelMaterialIDTag: Sendable {}
enum NovelMaterialRevisionIDTag: Sendable {}
enum NovelStateSnapshotIDTag: Sendable {}
enum NovelEventIDTag: Sendable {}
enum NovelCheckpointIDTag: Sendable {}
enum NovelOperationIDTag: Sendable {}
enum NovelRunIDTag: Sendable {}
enum NovelPendingOperationIDTag: Sendable {}
enum NovelReceiptIDTag: Sendable {}
enum NovelProposalIDTag: Sendable {}
enum NovelChapterPlanIDTag: Sendable {}

typealias NovelProjectID = NovelIdentifier<NovelProjectIDTag>
typealias NovelBranchID = NovelIdentifier<NovelBranchIDTag>
typealias NovelSessionID = NovelIdentifier<NovelSessionIDTag>
typealias NovelMessageID = NovelIdentifier<NovelMessageIDTag>
typealias NovelCandidateID = NovelIdentifier<NovelCandidateIDTag>
typealias NovelChapterID = NovelIdentifier<NovelChapterIDTag>
typealias NovelChapterVersionID = NovelIdentifier<NovelChapterVersionIDTag>
typealias NovelMaterialID = NovelIdentifier<NovelMaterialIDTag>
typealias NovelMaterialRevisionID = NovelIdentifier<NovelMaterialRevisionIDTag>
typealias NovelStateSnapshotID = NovelIdentifier<NovelStateSnapshotIDTag>
typealias NovelEventID = NovelIdentifier<NovelEventIDTag>
typealias NovelCheckpointID = NovelIdentifier<NovelCheckpointIDTag>
typealias NovelOperationID = NovelIdentifier<NovelOperationIDTag>
typealias NovelRunID = NovelIdentifier<NovelRunIDTag>
typealias NovelPendingOperationID = NovelIdentifier<NovelPendingOperationIDTag>
typealias NovelReceiptID = NovelIdentifier<NovelReceiptIDTag>
typealias NovelProposalID = NovelIdentifier<NovelProposalIDTag>
typealias NovelChapterPlanID = NovelIdentifier<NovelChapterPlanIDTag>
