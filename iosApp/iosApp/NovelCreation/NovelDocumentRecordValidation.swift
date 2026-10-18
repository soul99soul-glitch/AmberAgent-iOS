import Foundation

enum NovelDocumentRecordValidation {
    /// Quiet rest drops completed origin runs while leaving the proposals
    /// that named them. A later completed run of a different id must not
    /// resurrect the check. A run ID that is still present (wrong
    /// kind/status) is still a validator failure.
    private static func quietRestDroppedCompletedOriginRun(
        _ runID: NovelRunID,
        in document: NovelProjectDocumentV1
    ) -> Bool {
        !document.activeRuns.contains(where: { $0.id == runID })
    }

    static func validateProject(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let project = document.project
        if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Project name is empty.")
        }
        if project.revision < 1 { issues.append("Project revision must be positive.") }
        if project.configRevision < 1 { issues.append("Config revision must be positive.") }
        if project.updatedAt < project.createdAt { issues.append("Project timestamps move backwards.") }
        switch project.creationMode {
        case .blank where project.quickStartSeed != nil:
            issues.append("Blank project contains a quick-start seed.")
        case .quickStart where project.quickStartSeed == nil:
            issues.append("Quick-start project is missing its seed.")
        default:
            break
        }
        if case .fixed(let providerID, let modelID) = project.modelPolicy,
           providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Fixed project model policy has an empty stable ID.")
        }
        if case .fixed(let providerID, let modelID) = project.stateSyncModelPolicy,
           providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Fixed state-sync model policy has an empty stable ID.")
        }
        if case .fixed(let providerID, let modelID) = project.reviewModelPolicy,
           providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Fixed review model policy has an empty stable ID.")
        }

        appendDuplicateIssue(document.branches, key: \.id, label: "branch", issues: &issues)
        appendDuplicateIssue(document.sessions, key: \.id, label: "Session", issues: &issues)
        appendDuplicateIssue(document.materials, key: \.id, label: "material", issues: &issues)
        appendDuplicateIssue(document.materialRevisions, key: \.id, label: "material revision", issues: &issues)
        appendDuplicateIssue(document.chapters, key: \.id, label: "chapter", issues: &issues)
        appendDuplicateIssue(document.chapterVersions, key: \.id, label: "chapter version", issues: &issues)
        appendDuplicateIssue(document.events, key: \.id, label: "event", issues: &issues)
        appendDuplicateIssue(document.stateSnapshots, key: \.id, label: "state snapshot", issues: &issues)
        appendDuplicateIssue(document.checkpoints, key: \.id, label: "checkpoint", issues: &issues)
        appendDuplicateIssue(document.candidates, key: \.id, label: "candidate", issues: &issues)
        appendDuplicateIssue(document.injectionReceipts, key: \.id, label: "injection receipt", issues: &issues)
        appendDuplicateIssue(document.generationReceipts, key: \.id, label: "generation receipt", issues: &issues)
        appendDuplicateIssue(
            document.factAttempts,
            key: \.attemptOperationID,
            label: "fact attempt",
            issues: &issues
        )
        appendDuplicateIssue(document.pendingOperations, key: \.id, label: "pending operation", issues: &issues)
        appendDuplicateIssue(document.activeRuns, key: \.id, label: "active run", issues: &issues)
        appendDuplicateIssue(document.settingProposals, key: \.id, label: "setting proposal", issues: &issues)
        appendDuplicateIssue(document.appliedOperations, key: \.operationID, label: "operation", issues: &issues)
        appendDuplicateIssue(document.chapterPlans, key: \.id, label: "chapter plan", issues: &issues)
        appendDuplicateIssue(document.chapterPlans, key: \.branchID, label: "chapter plan branch", issues: &issues)
        for plan in document.chapterPlans {
            if !document.branches.contains(where: { $0.id == plan.branchID }) {
                issues.append("Chapter plan \(plan.id) references a missing branch.")
            }
            let expectedDigest = NovelChapterPlanRecord.digest(
                forCanonicalPayload: plan.canonicalDigestPayload()
            )
            if plan.contentDigest != expectedDigest {
                issues.append("Chapter plan \(plan.id) digest does not match its content.")
            }
            if plan.status == .confirmed {
                if plan.confirmedAt == nil {
                    issues.append("Confirmed chapter plan \(plan.id) is missing confirmedAt.")
                }
                if plan.mustHappen.isEmpty {
                    issues.append("Confirmed chapter plan \(plan.id) has no must-happen items.")
                }
            }
            if plan.goalAndConflict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Chapter plan \(plan.id) is missing a goal and conflict.")
            }
        }
        appendDuplicateIssue(
            document.upcomingArcs,
            key: \.branchID,
            label: "upcoming arc branch",
            issues: &issues
        )
        for arc in document.upcomingArcs {
            if !document.branches.contains(where: { $0.id == arc.branchID }) {
                issues.append("Upcoming arc references a missing branch \(arc.branchID).")
            }
            if arc.beats.isEmpty {
                issues.append("Upcoming arc for branch \(arc.branchID) has no beats.")
            }
            if arc.beats != NovelUpcomingArcRecord.normalizedBeats(arc.beats) {
                issues.append("Upcoming arc for branch \(arc.branchID) is not normalized.")
            }
        }
    }

    static func validateMaterials(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        var revisionByID: [NovelMaterialRevisionID: NovelMaterialRevisionRecord] = [:]
        for revision in document.materialRevisions where revisionByID[revision.id] == nil {
            revisionByID[revision.id] = revision
        }
        let operationIDs = Set(document.appliedOperations.map(\.operationID))
        let operationIndex = Dictionary(
            document.appliedOperations.enumerated().map { ($0.element.operationID, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        for material in document.materials {
            if material.kind != .character, !material.aliases.isEmpty {
                issues.append("Non-character material \(material.id) contains character aliases.")
            }
            if material.aliases != NovelCharacterIdentityResolver.normalizedAliases(material.aliases) {
                issues.append("Material \(material.id) contains invalid or duplicate aliases.")
            }
            if material.revisionIDs.isEmpty {
                issues.append("Material \(material.id) has no revisions.")
            }
            if Set(material.revisionIDs).count != material.revisionIDs.count {
                issues.append("Material \(material.id) repeats a revision reference.")
            }
            guard material.revisionIDs.contains(material.currentRevisionID) else {
                issues.append("Material \(material.id) current revision is not in its history.")
                continue
            }
            for (offset, revisionID) in material.revisionIDs.enumerated() {
                guard let revision = revisionByID[revisionID] else {
                    issues.append("Material \(material.id) references a missing revision.")
                    continue
                }
                if revision.materialID != material.id {
                    issues.append("Material revision \(revision.id) belongs to another material.")
                }
                if revision.revision != Int64(offset + 1) {
                    issues.append("Material \(material.id) revision numbers are not contiguous.")
                }
                if !operationIDs.contains(revision.operationID) {
                    issues.append("Material revision \(revision.id) has no applied operation.")
                }
            }
            let deleteOwners = document.appliedOperations.enumerated().filter { _, operation in
                guard operation.kind == .deleteMaterial,
                      case let .materialDeleted(_, materialID, _, _) = operation.outcome else {
                    return false
                }
                return materialID == material.id
            }
            if material.isDeleted {
                if deleteOwners.count != 1 {
                    issues.append("Deleted material \(material.id) has no unique delete operation.")
                } else if let deleteIndex = deleteOwners.first?.offset,
                          material.revisionIDs.contains(where: { revisionID in
                              guard let revision = revisionByID[revisionID],
                                    let revisionIndex = operationIndex[revision.operationID] else {
                                  return false
                              }
                              return revisionIndex >= deleteIndex
                          }) {
                    issues.append("Deleted material \(material.id) has a revision at or after deletion.")
                }
            } else if !deleteOwners.isEmpty {
                issues.append("Active material \(material.id) has a delete operation.")
            }
        }
        for revision in document.materialRevisions {
            guard let material = document.materials.first(where: { $0.id == revision.materialID }) else {
                issues.append("Material revision \(revision.id) has no material.")
                continue
            }
            if !material.revisionIDs.contains(revision.id) {
                issues.append("Material revision \(revision.id) is omitted from its material history.")
            }
        }
    }

    static func validateSessionsAndBranches(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let activeBranches = document.branches.filter { $0.lifecycle == .active }
        if activeBranches.isEmpty { issues.append("Project has no active branches.") }
        guard let mainBranch = document.branches.first(where: {
            $0.id == document.project.mainBranchID
        }), mainBranch.lifecycle == .active else {
            issues.append("Main branch is missing or deleted.")
            return
        }

        if Set(document.branches.map(\.sessionID)).count != document.branches.count {
            issues.append("A creation Session is shared by multiple branches.")
        }
        let allMessageIDs = document.sessions.flatMap { $0.messages.map(\.id) }
        if Set(allMessageIDs).count != allMessageIDs.count {
            issues.append("A message ID is shared by multiple creation Sessions.")
        }
        let allArchiveIDs = document.sessions.flatMap {
            ($0.discussionArchives ?? []).map(\.id)
        }
        if Set(allArchiveIDs).count != allArchiveIDs.count ||
            !Set(allArchiveIDs).isDisjoint(with: allMessageIDs) {
            issues.append("A discussion archive ID is repeated or collides with a Session message.")
        }
        for branch in document.branches {
            if branch.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Branch \(branch.id) has an empty name.")
            }
            if branch.headRevision < 0 || branch.workingRevision < 0 {
                issues.append("Branch \(branch.id) has a negative revision.")
            }
            guard let session = document.sessions.first(where: { $0.id == branch.sessionID }) else {
                issues.append("Branch \(branch.id) has no Session.")
                continue
            }
            if session.branchID != branch.id {
                issues.append("Branch \(branch.id) and Session \(session.id) disagree on ownership.")
            }
            let expectedSequences = session.messages.indices.map(Int64.init)
            if session.messages.map(\.sequence) != expectedSequences {
                issues.append("Session \(session.id) message sequence is not contiguous.")
            }
            if Set(session.messages.map(\.id)).count != session.messages.count {
                issues.append("Session \(session.id) repeats a message ID.")
            }
            let archives = session.discussionArchives ?? []
            for archive in archives {
                if archive.messageCount <= 0 ||
                    archive.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    archive.summary.count > 300 {
                    issues.append("Discussion archive \(archive.id) has invalid presentation data.")
                }
                if !session.messages.contains(where: { $0.sequence == archive.throughSequence }) {
                    issues.append("Discussion archive \(archive.id) has an invalid Session cursor.")
                }
                if let chapterID = archive.chapterID,
                   !document.chapters.contains(where: { $0.id == chapterID }) {
                    issues.append("Discussion archive \(archive.id) references a missing chapter.")
                }
                guard let checkpoint = document.checkpoints.first(where: {
                    $0.id == archive.checkpointID
                }) else {
                    issues.append("Discussion archive \(archive.id) has no checkpoint.")
                    continue
                }
                // Residual archives after undo stay on the creating branch; forks keep the source
                // archive checkpoint id while it remains in head lineage.
                let onCreatingBranch = checkpoint.createdOnBranchID == branch.id
                let inHeadLineage = NovelDocumentCheckpointValidation.checkpointIsAncestorOrSelf(
                    archive.checkpointID,
                    of: branch.headCheckpointID,
                    in: document
                )
                let checkpointCoversArchive = switch checkpoint.sessionCursor {
                case .through(let sequence): sequence >= archive.throughSequence
                case .empty: false
                }
                if checkpoint.kind != .discussionArchive ||
                    !checkpointCoversArchive ||
                    !(onCreatingBranch || inHeadLineage) {
                    issues.append("Discussion archive \(archive.id) disagrees with its checkpoint.")
                }
            }
            let activeArchives = archives.filter {
                NovelDocumentCheckpointValidation.checkpointIsAncestorOrSelf(
                    $0.checkpointID,
                    of: branch.headCheckpointID,
                    in: document
                )
            }
            let expectedArchiveCursor = activeArchives.max {
                $0.throughSequence < $1.throughSequence
            }.map { NovelSessionCursor.through(sequence: $0.throughSequence) }
            if session.archiveCursor != expectedArchiveCursor {
                issues.append("Session \(session.id) archive cursor disagrees with branch history.")
            }
            validateSessionInteractions(session, issues: &issues)
            guard let head = document.checkpoints.first(where: {
                $0.id == branch.headCheckpointID
            }) else {
                issues.append("Branch \(branch.id) has no valid head checkpoint.")
                continue
            }
            if head.stateSnapshotID != branch.currentStateSnapshotID {
                issues.append("Branch \(branch.id) state does not match its head checkpoint.")
            }
            if branch.syncStatus == .synchronized,
               branch.workingChapterSelections != head.chapterSelections {
                issues.append("Synchronized branch \(branch.id) working manuscript differs from its head.")
            }
            if Set(branch.workingChapterSelections.map(\.chapterID)).count !=
                branch.workingChapterSelections.count {
                issues.append("Branch \(branch.id) working manuscript repeats a chapter.")
            }
            for selection in branch.workingChapterSelections where
                !document.chapterVersions.contains(where: {
                    $0.id == selection.versionID && $0.chapterID == selection.chapterID
                }) {
                issues.append("Branch \(branch.id) working manuscript has an invalid chapter version.")
            }
            for revisionID in branch.overrideRevisionIDs where
                !document.materialRevisions.contains(where: { $0.id == revisionID }) {
                issues.append("Branch \(branch.id) has a missing override revision.")
            }
            let overrideMaterialIDs = branch.overrideRevisionIDs.compactMap { revisionID in
                document.materialRevisions.first(where: { $0.id == revisionID })?.materialID
            }
            if Set(branch.overrideRevisionIDs).count != branch.overrideRevisionIDs.count ||
                Set(overrideMaterialIDs).count != overrideMaterialIDs.count {
                issues.append("Branch \(branch.id) repeats a material override.")
            }
            if let origin = branch.forkOrigin {
                if !document.branches.contains(where: { $0.id == origin.parentBranchID }) {
                    issues.append("Branch \(branch.id) has a missing fork parent.")
                }
                if !document.checkpoints.contains(where: { $0.id == origin.checkpointID }) {
                    issues.append("Branch \(branch.id) has a missing fork checkpoint.")
                }
                let forkOwners = document.appliedOperations.filter { operation in
                    guard operation.kind == .forkBranch,
                          case let .branchForked(
                              _, sourceBranchID, branchID, checkpointID, _
                          ) = operation.outcome else {
                        return false
                    }
                    return sourceBranchID == origin.parentBranchID &&
                        branchID == branch.id &&
                        checkpointID == origin.checkpointID
                }
                if forkOwners.count != 1 {
                    issues.append("Branch \(branch.id) has no unique fork operation.")
                }
            }
            if branch.lifecycle == .deleted {
                let deleteOwners = document.appliedOperations.filter { operation in
                    guard operation.kind == .deleteBranch,
                          case let .branchDeleted(_, branchID, _) = operation.outcome else {
                        return false
                    }
                    return branchID == branch.id
                }
                if deleteOwners.count != 1 {
                    issues.append("Deleted branch \(branch.id) has no unique delete operation.")
                }
            }
            if branch.lifecycle == .deleted,
               branch.activeRunID != nil ||
                document.pendingOperations.contains(where: { $0.branchID == branch.id }) ||
                document.polishTransactions.contains(where: {
                    $0.branchID == branch.id &&
                        ($0.status == .pending || $0.status == .retryable)
                }) {
                issues.append("Deleted branch \(branch.id) still owns active work.")
            }
        }
        for session in document.sessions where
            !document.branches.contains(where: { $0.id == session.branchID && $0.sessionID == session.id }) {
            issues.append("Session \(session.id) has no owning branch.")
        }
    }

    private static func validateSessionInteractions(
        _ session: NovelSessionRecord,
        issues: inout [String]
    ) {
        var askPrompts: [NovelMessageID: NovelAskUserPrompt] = [:]
        var answeredPromptIDs: Set<NovelMessageID> = []
        for message in session.messages {
            switch message.interaction {
            case .askUser(let prompt):
                if message.role != .assistant || message.mode != .discussPlan || message.kind != .discussion {
                    issues.append("Ask User message \(message.id) has an invalid role or mode.")
                }
                do {
                    try NovelGenerationReducer.validateAskUserPrompt(prompt)
                    askPrompts[message.id] = prompt
                } catch {
                    issues.append("Ask User message \(message.id) has an invalid prompt.")
                }
            case .askUserAnswer(let response):
                if message.role != .user || message.mode != .discussPlan || message.kind != .userInput {
                    issues.append("Ask User answer \(message.id) has an invalid role or mode.")
                }
                guard askPrompts[response.promptMessageID] != nil else {
                    issues.append("Ask User answer \(message.id) references a missing or later prompt.")
                    continue
                }
                if !answeredPromptIDs.insert(response.promptMessageID).inserted {
                    issues.append("Ask User prompt \(response.promptMessageID) has multiple answers.")
                }
            case nil:
                break
            }
        }
    }

    static func validateChaptersAndState(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let operationIDs = Set(document.appliedOperations.map(\.operationID))
        // 预建索引：快照/版本循环里逐个线性查找在长篇项目上是 O(n·m)，
        // 真机每次提交都整份校验，这里曾占校验耗时近半。
        let chapterIDs = Set(document.chapters.map(\.id))
        let settingProposalIDs = Set(document.settingProposals.map(\.id))
        let checkpointStateSnapshotIDs = Set(document.checkpoints.map(\.stateSnapshotID))
        for version in document.chapterVersions {
            if !chapterIDs.contains(version.chapterID) {
                issues.append("Chapter version \(version.id) has no chapter.")
            }
            if !operationIDs.contains(version.operationID) {
                issues.append("Chapter version \(version.id) has no applied operation.")
            }
        }
        var eventByID: [NovelEventID: NovelStoryEventRecord] = [:]
        for event in document.events where eventByID[event.id] == nil {
            eventByID[event.id] = event
        }
        let eventSequences = document.events.map(\.sequence)
        if eventSequences.contains(where: { $0 < 0 }) {
            issues.append("Story event sequences must be non-negative.")
        }
        if Set(eventSequences).count != eventSequences.count {
            issues.append("Story event sequences must be project-global and unique.")
        }
        if zip(eventSequences, eventSequences.dropFirst()).contains(where: { $0 >= $1 }) {
            issues.append("Story event history is not strictly increasing.")
        }
        for snapshot in document.stateSnapshots {
            let clarificationKeys = snapshot.characterIdentityClarifications.map {
                NovelCharacterIdentityResolver.normalize($0.mention)
            }
            if clarificationKeys.contains(where: { $0.isEmpty }) ||
                Set(clarificationKeys).count != clarificationKeys.count {
                issues.append("State snapshot \(snapshot.id) has invalid identity clarification names.")
            }
            for clarification in snapshot.characterIdentityClarifications {
                if clarification.mention.count > 200 ||
                    clarification.clarification.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty ||
                    clarification.clarification.count > 1_000 ||
                    !operationIDs.contains(clarification.operationID) {
                    issues.append("State snapshot \(snapshot.id) has invalid identity clarification data.")
                }
            }
            if Set(snapshot.eventIDs).count != snapshot.eventIDs.count {
                issues.append("State snapshot \(snapshot.id) repeats an event.")
            }
            var lastSequence: Int64?
            for eventID in snapshot.eventIDs {
                guard let event = eventByID[eventID] else {
                    issues.append("State snapshot \(snapshot.id) references a missing event.")
                    continue
                }
                if let lastSequence, event.sequence <= lastSequence {
                    issues.append("State snapshot \(snapshot.id) event order is not strictly increasing.")
                }
                lastSequence = event.sequence
            }
            if Set(snapshot.settingProposalIDs).count != snapshot.settingProposalIDs.count {
                issues.append("State snapshot \(snapshot.id) repeats a setting proposal.")
            }
            for proposalID in snapshot.settingProposalIDs where
                !settingProposalIDs.contains(proposalID) {
                issues.append("State snapshot \(snapshot.id) references a missing setting proposal.")
            }
            if !checkpointStateSnapshotIDs.contains(snapshot.id) {
                issues.append("State snapshot \(snapshot.id) has no checkpoint reference.")
            }
        }
    }

    static func validateSettingProposals(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        var quickStartKindCountsByRun: [NovelRunID: [String: Int]] = [:]
        var quickStartProposalsByRun: [NovelRunID: [NovelSettingProposalRecord]] = [:]
        var contextualProposalsByRun: [NovelRunID: [NovelSettingProposalRecord]] = [:]
        for proposal in document.settingProposals {
            if case .some(.contextualCharacter(
                let runID,
                let sourceMention,
                let suggestedKind
            )) = proposal.origin {
                if proposal.supersededByRunID != nil {
                    issues.append("Contextual character proposal \(proposal.id) is marked as superseded.")
                }
                contextualProposalsByRun[runID, default: []].append(proposal)
                guard let sourceRun = document.activeRuns.first(where: {
                    $0.id == runID &&
                        $0.branchID == proposal.branchID &&
                        $0.kind == .characterProposal &&
                        $0.status == .completed
                }) else {
                    if !quietRestDroppedCompletedOriginRun(runID, in: document) {
                        issues.append(
                            "Contextual character proposal \(proposal.id) has no completed source run."
                        )
                    }
                    continue
                }
                if NovelCharacterIdentityResolver.normalize(sourceMention) !=
                    NovelCharacterIdentityResolver.normalize(
                        sourceRun.contextualCharacterMention ?? ""
                    ) {
                    issues.append("Contextual character proposal \(proposal.id) changed its source mention.")
                }
                switch suggestedKind {
                case .character:
                    let aliasKeys = Set((proposal.suggestedCharacterAliases ?? []).map {
                        NovelCharacterIdentityResolver.normalize($0)
                    })
                    if !aliasKeys.contains(NovelCharacterIdentityResolver.normalize(sourceMention)) {
                        issues.append(
                            "Contextual character proposal \(proposal.id) does not retain its source mention."
                        )
                    }
                case .relationship, .world, .masterOutline:
                    if proposal.suggestedCharacterAliases != nil {
                        issues.append(
                            "Non-character contextual proposal \(proposal.id) contains character aliases."
                        )
                    }
                case .writingRequirements, .decisionLog, .custom:
                    issues.append(
                        "Contextual character proposal \(proposal.id) suggests an unsupported material kind."
                    )
                }
                continue
            }
            guard case .some(.quickStart(let runID, let suggestedKind)) = proposal.origin else {
                if proposal.supersededByRunID != nil {
                    issues.append("Non-quick-start proposal \(proposal.id) is marked as superseded.")
                }
                continue
            }
            quickStartProposalsByRun[runID, default: []].append(proposal)
            guard let sourceRun = document.activeRuns.first(where: {
                $0.id == runID &&
                    $0.branchID == proposal.branchID &&
                    $0.kind == .quickStart &&
                    $0.status == .completed
            }) else {
                if !quietRestDroppedCompletedOriginRun(runID, in: document) {
                    issues.append("Quick-start proposal \(proposal.id) has no completed source run.")
                }
                continue
            }
            if proposal.isResolved && proposal.supersededByRunID != nil {
                issues.append(
                    "Quick-start proposal \(proposal.id) is both resolved and superseded."
                )
            }
            if let supersedingRunID = proposal.supersededByRunID {
                guard let supersedingRun = document.activeRuns.first(where: {
                    $0.id == supersedingRunID &&
                        $0.id != runID &&
                        $0.branchID == proposal.branchID &&
                        $0.kind == .quickStart &&
                        $0.status == .completed
                }) else {
                    issues.append("Quick-start proposal \(proposal.id) has an invalid superseding run.")
                    continue
                }
                let sourceStartRevision = document.appliedOperations.first(where: {
                    $0.operationID == sourceRun.operationID && $0.kind == .startRun
                })?.appliedProjectRevision
                let supersedingStartRevision = document.appliedOperations.first(where: {
                    $0.operationID == supersedingRun.operationID && $0.kind == .startRun
                })?.appliedProjectRevision
                if let sourceStartRevision,
                   let supersedingStartRevision,
                   supersedingStartRevision <= sourceStartRevision {
                    issues.append(
                        "Quick-start superseding run \(supersedingRunID) must follow its source run \(runID)."
                    )
                }
            }
            let kindKey: String
            switch suggestedKind {
            case .world: kindKey = "world"
            case .character: kindKey = "character"
            case .masterOutline: kindKey = "masterOutline"
            case .writingRequirements: kindKey = "writingRequirements"
            case .relationship, .decisionLog, .custom:
                issues.append("Quick-start proposal \(proposal.id) suggests an unsupported material kind.")
                continue
            }
            quickStartKindCountsByRun[runID, default: [:]][kindKey, default: 0] += 1
        }
        for (runID, proposals) in quickStartProposalsByRun {
            let activeProposals = proposals.filter { !$0.isResolved }
            let supersededCount = activeProposals.filter {
                $0.supersededByRunID != nil
            }.count
            if supersededCount > 0 && supersededCount != activeProposals.count {
                issues.append("Quick-start proposal round \(runID) is partially superseded.")
            }
            if Set(activeProposals.compactMap(\.supersededByRunID)).count > 1 {
                issues.append(
                    "Quick-start proposal round \(runID) names multiple superseding runs."
                )
            }
        }
        for run in document.activeRuns where
            run.kind == .quickStart && run.status == .completed {
            let outputMessage = document.sessions
                .first(where: { $0.id == run.sessionID })?
                .messages
                .first(where: { $0.id == run.messageID })
            if case .some(.askUser(_)) = outputMessage?.interaction {
                if !(quickStartProposalsByRun[run.id] ?? []).isEmpty {
                    issues.append(
                        "Quick-start Ask User run \(run.id) unexpectedly owns setting proposals."
                    )
                }
                continue
            }
            let counts = quickStartKindCountsByRun[run.id] ?? [:]
            if counts["world"] != 1 ||
                counts["masterOutline"] != 1 ||
                counts["writingRequirements"] != 1 ||
                (counts["character"] ?? 0) < 1 {
                issues.append(
                    "Quick-start run \(run.id) does not own one fixed proposal per section and at least one character proposal."
                )
            }
        }
        for run in document.activeRuns where
            run.kind == .characterProposal && run.status == .completed {
            guard let output = try? NovelStructuredOutputDecoder.decodeCharacterProposal(
                from: run.partialContent
            ) else {
                issues.append("Completed character-proposal run \(run.id) has invalid output.")
                continue
            }
            let proposals = contextualProposalsByRun[run.id] ?? []
            let expectedKinds: [NovelMaterialKind] = [.character] +
                output.relatedSuggestions.map { suggestion in
                    switch suggestion.kind {
                    case .relationship: .relationship
                    case .world: .world
                    case .plot: .masterOutline
                    }
                }
            if proposals.map(\.suggestedMaterialKind) != expectedKinds {
                issues.append(
                    "Character-proposal run \(run.id) does not own its typed proposal set."
                )
            }
        }

        for proposal in document.settingProposals where proposal.isResolved {
            let owners = document.appliedOperations.filter { operation in
                guard operation.kind == .resolveSettingProposal else { return false }
                switch operation.outcome {
                case .settingProposalAccepted(_, let proposalID, _, _, _, _),
                     .settingProposalRejected(_, let proposalID, _, _):
                    return proposalID == proposal.id
                default:
                    return false
                }
            }
            if owners.count != 1 {
                issues.append("Resolved setting proposal \(proposal.id) has no unique resolution operation.")
            }
        }
    }

    private static func appendDuplicateIssue<Element, ID: Hashable>(
        _ elements: [Element],
        key: KeyPath<Element, ID>,
        label: String,
        issues: inout [String]
    ) {
        let ids = elements.map { $0[keyPath: key] }
        if Set(ids).count != ids.count {
            issues.append("Duplicate \(label) ID.")
        }
    }

}
