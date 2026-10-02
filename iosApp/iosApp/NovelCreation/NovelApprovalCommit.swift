import Foundation

/// Records an author approval in the same document revision as its mutation.
/// Completed generation records may be pruned; the session prompt is durable.
enum NovelApprovalCommit {
    private struct Payload: Encodable {
        let payloadSHA256: String
        let response: NovelAskUserResponse
    }

    static func payloadSHA256(_ original: String, response: NovelAskUserResponse?) throws -> String {
        guard let response else { return original }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return NovelProjectPackageCodec.sha256(try encoder.encode(Payload(
            payloadSHA256: original, response: response
        )))
    }

    static func append(
        _ response: NovelAskUserResponse?,
        branchID: NovelBranchID,
        to document: inout NovelProjectDocumentV1,
        now: Date
    ) throws {
        guard let response else { return }
        guard let branch = document.branches.first(where: { $0.id == branchID }) else {
            throw NovelError.branchNotFound(branchID)
        }
        guard let sessionIndex = document.sessions.firstIndex(where: { $0.id == branch.sessionID }),
              let message = document.sessions[sessionIndex].messages.first(where: {
                  $0.id == response.promptMessageID && $0.role == .assistant
              }), case .some(.askUser(let prompt)) = message.interaction else {
            throw NovelError.invalidInput("The approval prompt no longer belongs to this session.")
        }
        guard !document.sessions[sessionIndex].messages.contains(where: {
            if case .some(.askUserAnswer(let existing)) = $0.interaction {
                return existing.promptMessageID == response.promptMessageID
            }
            return false
        }) else {
            throw NovelError.invalidInput("This approval has already been answered.")
        }
        try NovelGenerationReducer.validateAskUserPrompt(prompt)
        let answer = response.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let approved: Bool
        if let proposal = prompt.ghostwritePlan {
            approved = NovelGhostwritePlanApproval.approvedChapterCount(from: answer) != nil
            guard proposal.projectID == document.project.id,
                  proposal.branchID == branchID,
                  document.confirmedChapterPlan(for: branchID)?.contentDigest == proposal.proposedPlanDigest,
                  document.project.collaborationMode == .ghostwrite,
                  proposal.upcomingArc.isEmpty || document.upcomingArc(for: branchID)?.beats
                    == NovelUpcomingArcRecord.normalizedBeats(proposal.upcomingArc) else {
                throw NovelError.invalidInput("The approved ghostwrite configuration has not been saved.")
            }
        } else if prompt.chapterRevision != nil {
            approved = answer == NovelChapterRevisionApproval.approveOption
        } else if prompt.workspacePlot != nil {
            approved = answer == NovelWorkspacePlotApproval.approveOption
        } else if let proposal = prompt.manuscriptRevert {
            approved = answer == NovelManuscriptRevertApproval.approveOption
            guard branch.headCheckpointID == proposal.targetCheckpointID else {
                throw NovelError.invalidInput("The approved manuscript revert has not finished.")
            }
        } else if let proposal = prompt.manuscriptDelete {
            approved = answer == NovelManuscriptDeleteApproval.approveOption
            guard !branch.workingChapterSelections.contains(where: {
                proposal.chapterIDs.contains($0.chapterID)
            }) else {
                throw NovelError.invalidInput("The approved manuscript deletion has not finished.")
            }
        } else {
            approved = false
        }
        guard approved else {
            throw NovelError.invalidInput("This answer does not approve the proposed mutation.")
        }
        let sequence = (document.sessions[sessionIndex].messages.last?.sequence ?? -1) + 1
        document.sessions[sessionIndex].messages.append(NovelSessionMessageRecord(
            id: NovelMessageID(),
            sequence: sequence,
            role: .user,
            mode: .discussPlan,
            kind: .userInput,
            content: answer,
            createdAt: now,
            runID: nil,
            candidateID: nil,
            interaction: .askUserAnswer(response)
        ))
        document.sessions[sessionIndex].revision += 1
    }
}
