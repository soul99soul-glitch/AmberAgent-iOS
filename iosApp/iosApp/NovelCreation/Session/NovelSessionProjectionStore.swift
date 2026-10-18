import Foundation

struct NovelSessionProjectionTailKey: Equatable {
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let runID: NovelRunID
    let userMessageID: NovelMessageID
    let messageID: NovelMessageID
    let candidateID: NovelCandidateID?
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let kind: NovelSessionMessageKind
    let startedAt: Date

    init(_ tail: NovelSessionTransientTail) {
        branchID = tail.branchID
        sessionID = tail.sessionID
        runID = tail.runID
        userMessageID = tail.userMessageID
        messageID = tail.messageID
        candidateID = tail.candidateID
        mode = tail.mode
        granularity = tail.granularity
        kind = tail.kind
        startedAt = tail.startedAt
    }
}

struct NovelSessionProjectionCacheKey: Equatable {
    let projectID: NovelProjectID
    let projectRevision: Int64
    let configRevision: Int64
    let projectAccess: NovelProjectLoadAccess
    let branchID: NovelBranchID
    let branchHeadRevision: Int64
    let branchWorkingRevision: Int64
    let branchSyncStatus: NovelBranchSyncStatus
    let branchLifecycle: NovelBranchLifecycle
    let activeRunID: NovelRunID?
    let sessionID: NovelSessionID
    let sessionRevision: Int64
    let expandedArchiveIDs: Set<NovelMessageID>
    let hasLiveTail: Bool

    init(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        expandedArchiveIDs: Set<NovelMessageID>,
        transientTail: NovelSessionTransientTail?
    ) {
        projectID = project.project.id
        projectRevision = project.project.revision
        configRevision = project.project.configRevision
        projectAccess = project.access
        branchID = branch.branch.id
        branchHeadRevision = branch.branch.headRevision
        branchWorkingRevision = branch.branch.workingRevision
        branchSyncStatus = branch.branch.syncStatus
        branchLifecycle = branch.branch.lifecycle
        activeRunID = branch.branch.activeRunID
        sessionID = branch.session.id
        sessionRevision = branch.session.revision
        self.expandedArchiveIDs = expandedArchiveIDs
        hasLiveTail = NovelSessionProjectionInput.hasLiveTail(
            transientTail,
            branchID: branch.branch.id,
            sessionID: branch.session.id
        )
    }
}

struct NovelSessionProjectionCacheEntry {
    let key: NovelSessionProjectionCacheKey
    let durableProjection: NovelSessionPreparedProjection
    let model: NovelSessionListModel
    let tailKey: NovelSessionProjectionTailKey?
    let tailStartingUserContent: String?
    let tailRenderRevision: UInt64?
    let localAskUserRevision: UInt64
}

struct NovelSessionTailChromeState: Equatable {
    let runID: NovelRunID?
    let phase: NovelSessionTransientTailPhase?
    let supportsReasoning: Bool

    init(_ tail: NovelSessionTransientTail?) {
        runID = tail?.runID
        phase = tail?.phase
        supportsReasoning = tail.map {
            $0.isReasoningLive || !$0.reasoningContent.isEmpty
        } ?? false
    }
}

struct NovelCharacterIdentityMentionsCacheKey: Equatable {
    let projectRevision: Int64
    let configRevision: Int64
    let branchID: NovelBranchID
    let stateSnapshotID: NovelStateSnapshotID
    let unresolvedNames: [String]
}

struct NovelCharacterIdentityMentionsCacheEntry {
    let key: NovelCharacterIdentityMentionsCacheKey
    let value: [NovelCharacterIdentityMention]
}

struct NovelCharacterIdentityCardFacts {
    let mention: NovelCharacterIdentityMention
    let recommended: (material: NovelMaterialRecord, title: String)?
    let activeProposal: NovelSettingProposalRecord?
    let relatedProposalCount: Int
}

struct NovelCharacterIdentityCardsCacheEntry {
    let key: NovelCharacterIdentityMentionsCacheKey
    let value: [NovelCharacterIdentityCardFacts]
}


extension NovelSessionViewModel {
    var durableMessages: [NovelSessionMessageRecord] {
        guard snapshotMatchesBinding else { return [] }
        return workspace.branchSnapshot?.session.messages ?? []
    }

    var hasArchivableDiscussion: Bool {
        guard snapshotMatchesBinding,
              let session = workspace.branchSnapshot?.session else { return false }
        if let cached = archivableDiscussionCache,
           cached.sessionID == session.id,
           cached.revision == session.revision,
           cached.archiveCursor == session.archiveCursor {
            return cached.value
        }
        let previousSequence: Int64 = switch session.archiveCursor {
        case .through(let sequence): sequence
        case .empty, nil: -1
        }
        let value = session.messages.contains {
            $0.sequence > previousSequence &&
                $0.mode == .discussPlan &&
                ($0.kind == .userInput || $0.kind == .discussion)
        }
        archivableDiscussionCache = (session.id, session.revision, session.archiveCursor, value)
        return value
    }

    var latestContextReceipt: NovelInjectionReceiptRecord? {
        guard let project = workspace.projectSnapshot,
              let branchID = binding?.branchID ?? workspace.selectedBranchID else { return nil }
        if let cached = latestContextReceiptCache,
           cached.projectID == project.project.id,
           cached.revision == project.project.revision,
           cached.branchID == branchID {
            return cached.value
        }
        let value = project.injectionReceipts
            .filter { $0.branchID == branchID && $0.factTransaction == nil }
            .max { $0.createdAt < $1.createdAt }
        latestContextReceiptCache = (project.project.id, project.project.revision, branchID, value)
        return value
    }

    /// Presentation-facing list: empty until secondary chrome stage so open layout
    /// does not pay identity resolution in the same frames as core transcript.
    var pendingCharacterIdentityMentions: [NovelCharacterIdentityMention] {
        guard loadStage >= .secondaryChrome else { return [] }
        return resolvedPendingCharacterIdentityMentions
    }

    /// Domain-facing list: independent of load stage. Actions/tests must use this
    /// so closed-loop is not coupled to presentation staging.
    var resolvedPendingCharacterIdentityMentions: [NovelCharacterIdentityMention] {
        guard snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return [] }
        let state = branch.currentState
        // Cache: body re-evaluates this getter continuously; large projects hit
        // 0x8BADF00D when this path (or the cards it drives) runs every frame.
        let cacheKey = NovelCharacterIdentityMentionsCacheKey(
            projectRevision: project.project.revision,
            configRevision: project.project.configRevision,
            branchID: branch.branch.id,
            stateSnapshotID: state.id,
            unresolvedNames: state.unresolvedEntityNames
        )
        if let cached = pendingCharacterIdentityMentionsCache, cached.key == cacheKey {
            return cached.value
        }

        // Fast known-set only: current titles + stored aliases.
        // Do NOT walk appliedOperations / settingProposals / revision history here —
        // that O(ops × materials) work used to freeze session open on 赵大来了-scale
        // projects. Missing a historical alias only risks an extra card, not data loss.
        var knownKeys: Set<String> = []
        knownKeys.reserveCapacity(max(16, workspace.activeMaterials.count * 2))
        for material in workspace.activeMaterials where material.kind == .character {
            if let revision = NovelPresentation.effectiveRevision(
                for: material,
                project: project,
                branch: branch
            ) {
                let titleKey = NovelCharacterIdentityResolver.normalize(revision.title)
                if !titleKey.isEmpty { knownKeys.insert(titleKey) }
            }
            for alias in material.aliases {
                let aliasKey = NovelCharacterIdentityResolver.normalize(alias)
                if !aliasKey.isEmpty { knownKeys.insert(aliasKey) }
            }
        }
        let clarifiedKeys = Set(
            state.characterIdentityClarifications.map {
                NovelCharacterIdentityResolver.normalize($0.mention)
            }
        )
        var namesByKey: [String: String] = [:]
        for name in state.unresolvedEntityNames {
            let key = NovelCharacterIdentityResolver.normalize(name)
            // Immediate presentation filter: stale place names already stored
            // in unresolvedEntityNames must not open as 「确认人物身份」 cards.
            guard !key.isEmpty,
                  NovelCharacterIdentityResolver.isLikelyCharacterIdentityCandidate(name),
                  !clarifiedKeys.contains(key),
                  !knownKeys.contains(key) else { continue }
            namesByKey[key] = name
        }
        let value = namesByKey.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map(NovelCharacterIdentityMention.init(name:))
        pendingCharacterIdentityMentionsCache = NovelCharacterIdentityMentionsCacheEntry(
            key: cacheKey,
            value: value
        )
        return value
    }

    /// Cap session cards so a large unresolved set cannot paint dozens of heavy
    /// forms in one ScrollView body (true freeze source after open).
    static let maxVisibleCharacterIdentityCards = 3
    /// Cap inline choice buttons; longer character rosters use a compact menu.
    static let maxInlineCharacterIdentityChoices = 6

    /// Presentation-facing choices (stage-gated). Domain/actions use
    /// `resolvedCharacterIdentityChoices`.
    var characterIdentityChoices: [(material: NovelMaterialRecord, title: String)] {
        guard loadStage >= .secondaryChrome else { return [] }
        return resolvedCharacterIdentityChoices
    }

    var resolvedCharacterIdentityChoices: [(material: NovelMaterialRecord, title: String)] {
        guard snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return [] }
        let rev = project.project.revision
        let config = project.project.configRevision
        if let cached = characterIdentityChoicesCache,
           cached.projectRevision == rev,
           cached.configRevision == config,
           cached.branchID == branch.branch.id,
           cached.stateSnapshotID == branch.currentState.id {
            return cached.value
        }
        // Titles only — do not expand proposal/history aliases here.
        let value: [(material: NovelMaterialRecord, title: String)] = workspace.activeMaterials
            .compactMap { material in
                guard material.kind == .character,
                      let revision = NovelPresentation.effectiveRevision(
                          for: material,
                          project: project,
                          branch: branch
                      ) else { return nil }
                return (material, revision.title)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        characterIdentityChoicesCache = (rev, config, branch.branch.id, branch.currentState.id, value)
        return value
    }

    var characterIdentityCardFacts: [NovelCharacterIdentityCardFacts] {
        guard loadStage >= .secondaryChrome,
              snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return [] }
        let state = branch.currentState
        let key = NovelCharacterIdentityMentionsCacheKey(
            projectRevision: project.project.revision,
            configRevision: project.project.configRevision,
            branchID: branch.branch.id,
            stateSnapshotID: state.id,
            unresolvedNames: state.unresolvedEntityNames
        )
        if let cached = characterIdentityCardsCache, cached.key == key {
            return cached.value
        }
        let value = resolvedPendingCharacterIdentityMentions
            .prefix(Self.maxVisibleCharacterIdentityCards)
            .map { mention in
                NovelCharacterIdentityCardFacts(
                    mention: mention,
                    recommended: recommendedCharacterIdentityChoice(for: mention.name),
                    activeProposal: activeCharacterProposal(for: mention.name),
                    relatedProposalCount: relatedCharacterProposalCount(for: mention.name)
                )
            }
        characterIdentityCardsCache = NovelCharacterIdentityCardsCacheEntry(key: key, value: value)
        return value
    }

    /// Best existing character for a pending mention (deterministic, offline).
    /// Used for the one-tap 「确认为…」 primary action on identity cards.
    func recommendedCharacterIdentityChoice(
        for mention: String
    ) -> (material: NovelMaterialRecord, title: String)? {
        let choices = resolvedCharacterIdentityChoices
        guard !choices.isEmpty else { return nil }
        let candidates = choices.map { choice in
            (
                id: choice.material.id.description,
                title: choice.title,
                aliases: workspace.effectiveAliases(for: choice.material)
            )
        }
        guard let match = NovelCharacterIdentityResolver.recommendedIdentityMatch(
            mention: mention,
            candidates: candidates
        ) else { return nil }
        return choices.first {
            $0.material.id.description == match.id
        }
    }

    /// Advance open staging. Call only from the session view's sequenced open task
    /// (or binding reset). Stages only move forward, except reset to `.idle`.
    /// Non-idle targets require an established core bind first (no idle→secondary leap).
    func advanceLoadStage(to stage: NovelSessionLoadStage) {
        if stage == .idle {
            loadStage = .idle
            pendingCharacterIdentityMentionsCache = nil
            characterIdentityCardsCache = nil
            characterIdentityChoicesCache = nil
            return
        }
        guard stage > loadStage else { return }
        if stage > .coreTranscript, loadStage < .coreTranscript {
            // Cannot skip past core without a successful bind.
            return
        }
        loadStage = stage
        // Warm identity caches once when secondary chrome opens so the first body
        // that paints cards does not pay resolution + choice sort mid-layout.
        if stage >= .secondaryChrome {
            _ = resolvedPendingCharacterIdentityMentions
            _ = resolvedCharacterIdentityChoices
            _ = characterIdentityCardFacts
        }
    }

    func activeCharacterProposal(
        for mention: String
    ) -> NovelSettingProposalRecord? {
        let key = NovelCharacterIdentityResolver.normalize(mention)
        return workspace.branchSnapshot?.activeSettingProposals.first { proposal in
            guard case .some(.contextualCharacter(
                _,
                let sourceMention,
                .character
            )) = proposal.origin else { return false }
            return NovelCharacterIdentityResolver.normalize(sourceMention) == key
        }
    }

    func relatedCharacterProposalCount(for mention: String) -> Int {
        let key = NovelCharacterIdentityResolver.normalize(mention)
        return workspace.branchSnapshot?.activeSettingProposals.filter { proposal in
            guard case .some(.contextualCharacter(
                _,
                let sourceMention,
                let kind
            )) = proposal.origin,
                  kind != .character else { return false }
            return NovelCharacterIdentityResolver.normalize(sourceMention) == key
        }.count ?? 0
    }

    func projectedListModel(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        expandedArchiveIDs: Set<NovelMessageID> = []
    ) -> NovelSessionListModel? {
        guard binding?.projectID == project.project.id,
              binding?.branchID == branch.branch.id else { return nil }
        // The detached durable build announces installation through this observed
        // revision; the cache itself stays observation-ignored at streaming cadence.
        _ = projectionRevision
        projectionExpandedArchiveIDs = expandedArchiveIDs
        let key = NovelSessionProjectionCacheKey(
            project: project,
            branch: branch,
            expandedArchiveIDs: expandedArchiveIDs,
            transientTail: transientTail
        )
        if let cached = projectionCache {
            let tailKey = transientTail.map(NovelSessionProjectionTailKey.init)
            if cached.key == key,
               cached.tailKey == tailKey,
               cached.tailStartingUserContent == transientTail?.startingUserContent,
               cached.tailRenderRevision == transientTail?.renderRevision,
               cached.localAskUserRevision == localAskUserRevision {
                return cached.model
            }
            let model: NovelSessionListModel
            if let tail = transientTail,
               cached.tailKey == tailKey,
               cached.tailStartingUserContent == tail.startingUserContent,
               cached.localAskUserRevision == localAskUserRevision,
               let patched = NovelSessionPresentation.updatingTransientTail(
                   in: cached.model,
                   with: tail,
                   input: cached.model.activeTailRow?.transientPhase == tail.phase
                       ? nil
                       : NovelSessionProjectionInput(
                           project: project,
                           branch: branch,
                           expandedArchiveIDs: expandedArchiveIDs,
                           transientTail: tail
                       ),
                   prepared: cached.durableProjection,
                   localAskUserResponse: locallyResolvedAskUser[tail.messageID]
               ) {
                model = cached.model.activeTailRow?.transientPhase == tail.phase
                    ? patched
                    : overlayLocalAskUserAnswers(patched)
            } else {
                let input = NovelSessionProjectionInput(
                    project: project,
                    branch: branch,
                    expandedArchiveIDs: expandedArchiveIDs,
                    transientTail: transientTail
                )
                model = overlayLocalAskUserAnswers(
                    NovelSessionPresentation.applyingTransientTail(
                        to: cached.durableProjection,
                        input: input
                    )
                )
            }
            let visibleModel = key.hasLiveTail && !cached.key.hasLiveTail
                ? NovelSessionPresentation.blockingDurableActionsForLiveTail(
                    in: model,
                    access: project.access,
                    lifecycle: branch.branch.lifecycle
                )
                : model
            projectionCache = NovelSessionProjectionCacheEntry(
                key: cached.key,
                durableProjection: cached.durableProjection,
                model: visibleModel,
                tailKey: tailKey,
                tailStartingUserContent: transientTail?.startingUserContent,
                tailRenderRevision: transientTail?.renderRevision,
                localAskUserRevision: localAskUserRevision
            )
            if cached.key != key {
                scheduleProjectionCache(project: project, branch: branch, key: key)
            }
            return visibleModel
        }
        scheduleProjectionCache(project: project, branch: branch, key: key)
        return nil
    }

    private func overlayLocalAskUserAnswers(_ model: NovelSessionListModel) -> NovelSessionListModel {
        guard !locallyResolvedAskUser.isEmpty else { return model }
        var changed = false
        let rows = model.rows.map { row -> NovelSessionRowModel in
            guard let askUser = row.askUser,
                  askUser.response == nil,
                  let response = locallyResolvedAskUser[row.id] else {
                return row
            }
            changed = true
            let resolved = NovelAskUserPresentation(prompt: askUser.prompt, response: response)
            return NovelSessionRowModel(
                id: row.id,
                sequence: row.sequence,
                role: row.role,
                mode: row.mode,
                granularity: row.granularity,
                kind: row.kind,
                content: row.content,
                reasoningContent: row.reasoningContent,
                isReasoningLive: row.isReasoningLive,
                createdAt: row.createdAt,
                runID: row.runID,
                runStatus: row.runStatus,
                candidate: row.candidate,
                committedChange: row.committedChange,
                askUser: resolved,
                archive: row.archive,
                transientPhase: row.transientPhase,
                actions: row.actions,
                digest: NovelSessionRowDigest(
                    layout: row.digest.layout.replacingOccurrences(of: ":pending;", with: ":answered;"),
                    presentation: row.digest.presentation
                ),
                lagAllowance: row.lagAllowance
            )
        }
        guard changed else { return model }
        return NovelSessionListModel(
            sessionID: model.sessionID,
            rows: rows,
            activeTailID: model.activeTailID
        )
    }

    /// Build the session list model off the main actor, then install the cache.
    /// Call before advancing to `.coreTranscript` on cold open.
    @discardableResult
    func warmProjectionCache(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        expandedArchiveIDs: Set<NovelMessageID>
    ) async -> Bool {
        let expectedToken = bindingToken
        projectionExpandedArchiveIDs = expandedArchiveIDs
        var currentProject = project
        var currentBranch = branch
        while true {
            guard !Task.isCancelled, bindingToken == expectedToken else { return false }
            let key = NovelSessionProjectionCacheKey(
                project: currentProject,
                branch: currentBranch,
                expandedArchiveIDs: projectionExpandedArchiveIDs,
                transientTail: transientTail
            )
            if projectionCache?.key == key { return true }
            scheduleProjectionCache(project: currentProject, branch: currentBranch, key: key)
            guard let task = projectionBuildTask else { return false }
            if await task.value { return true }
            guard !Task.isCancelled,
                  bindingToken == expectedToken,
                  let nextProject = workspace.projectSnapshot,
                  let nextBranch = workspace.branchSnapshot,
                  binding?.projectID == nextProject.project.id,
                  binding?.branchID == nextBranch.branch.id,
                  snapshotMatchesBinding else { return false }
            // An archive expansion or newer durable snapshot superseded the
            // in-flight build. The same key may already have a replacement
            // build (expand then collapse); keep waiting for the current one.
            currentProject = nextProject
            currentBranch = nextBranch
        }
    }

    func cancelProjectionBuild() {
        projectionBuildTask?.cancel()
        projectionBuildTask = nil
        projectionBuildKey = nil
        projectionBuildID = nil
    }

    private func scheduleProjectionCache(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        key: NovelSessionProjectionCacheKey
    ) {
        guard projectionBuildKey != key || projectionBuildTask == nil else { return }
        projectionBuildTask?.cancel()
        let buildID = UUID()
        let token = bindingToken
        projectionBuildKey = key
        projectionBuildID = buildID
        let input = NovelSessionProjectionInput(
            project: project,
            branch: branch,
            expandedArchiveIDs: key.expandedArchiveIDs,
            transientTail: nil,
            hasLiveTail: key.hasLiveTail
        )
        projectionBuildTask = Task { @MainActor [weak self] in
            let durableModel = await Task.detached(priority: .userInitiated) {
                NovelSessionPresentation.prepareDurable(input)
            }.value
            guard let self else { return false }
            defer {
                if self.projectionBuildID == buildID {
                    self.projectionBuildTask = nil
                    self.projectionBuildKey = nil
                    self.projectionBuildID = nil
                }
            }
            guard !Task.isCancelled,
                  self.projectionBuildID == buildID,
                  self.bindingToken == token,
                  self.binding?.projectID == project.project.id,
                  self.binding?.branchID == branch.branch.id,
                  let currentProject = self.workspace.projectSnapshot,
                  let currentBranch = self.workspace.branchSnapshot,
                  self.workspace.selectedProjectID == key.projectID,
                  self.workspace.selectedBranchID == key.branchID,
                  NovelSessionProjectionCacheKey(
                      project: currentProject,
                      branch: currentBranch,
                      expandedArchiveIDs: self.projectionExpandedArchiveIDs,
                      transientTail: self.transientTail
                  ) == key else { return false }
            let currentInput = NovelSessionProjectionInput(
                project: currentProject,
                branch: currentBranch,
                expandedArchiveIDs: key.expandedArchiveIDs,
                transientTail: self.transientTail
            )
            let model = self.overlayLocalAskUserAnswers(
                NovelSessionPresentation.applyingTransientTail(
                    to: durableModel,
                    input: currentInput
                )
            )
            self.projectionCache = NovelSessionProjectionCacheEntry(
                key: key,
                durableProjection: durableModel,
                model: model,
                tailKey: self.transientTail.map(NovelSessionProjectionTailKey.init),
                tailStartingUserContent: self.transientTail?.startingUserContent,
                tailRenderRevision: self.transientTail?.renderRevision,
                localAskUserRevision: self.localAskUserRevision
            )
            #if DEBUG
            self.fullProjectionBuildCountForTesting += 1
            #endif
            self.projectionRevision &+= 1
            return true
        }
    }

}
