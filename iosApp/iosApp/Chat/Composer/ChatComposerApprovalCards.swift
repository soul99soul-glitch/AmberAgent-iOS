import Foundation
import SwiftUI
@preconcurrency import Shared

/// The pending gate cards share a single bounded approval viewport.
@MainActor
struct ChatComposerApprovalCards: View {
    let viewModel: ChatViewModel
    let onOpenSession: (String?) -> (() -> Void)?
    let maximumHeight: CGFloat
    let webMountApprovalTransition: AnyTransition
    let ishApprovalTransition: AnyTransition
    let ishApprovalVisibilityAnimation: Animation?
    @Binding var gateHighlightRequest: UUID?
    @Binding var siteMemoryApprovalMinimumHeights: [String: CGFloat]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let descriptor = viewModel.pendingToolOutcomeUnknown {
                ToolOutcomeUnknownCard(
                    descriptor: descriptor,
                    onDidApply: {
                        Task { await viewModel.reconcilePendingToolOutcome(didApply: true) }
                    },
                    onDidNotApply: {
                        Task { await viewModel.reconcilePendingToolOutcome(didApply: false) }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Site-memory review information shares the bounded preview's scroll area.
            // Other approval types retain their existing header layout.
            if viewModel.pendingWebMountApproval?.siteMemoryChanges == nil {
                if let reasons = viewModel.jevAutoApprovalEscalation {
                    JevAutoApprovalEscalationNote(reasons: reasons)
                        .transition(.opacity)
                }
                if let triage = viewModel.jevApprovalTriage {
                    JevApprovalTriageChips(triage: triage)
                        .transition(.opacity)
                }
            }

            if let request = viewModel.pendingMemoryApproval {
                MemoryToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingMemoryTool()
                    },
                    onDeny: {
                        viewModel.denyPendingMemoryTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingSearchApproval {
                SearchToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingSearchTool()
                    },
                    onDeny: {
                        viewModel.denyPendingSearchTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingWebMountApproval {
                WebMountToolApprovalCard(
                    request: request,
                    onOpenSession: onOpenSession(request.sessionId),
                    onApprove: {
                        viewModel.approvePendingWebMountTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingWebMountTool(requestId: request.id)
                    },
                    maximumHeight: maximumHeight,
                    jevReviewReasons: viewModel.jevAutoApprovalEscalation,
                    jevTriage: viewModel.jevApprovalTriage
                )
                .buttonStyle(.plain)
                .onPreferenceChange(WebMountSiteMemoryApprovalMinimumHeightKey.self) { heights in
                    if siteMemoryApprovalMinimumHeights != heights { siteMemoryApprovalMinimumHeights = heights }
                }
                .id(request.id)
                .transition(webMountApprovalTransition)
            }

            if let request = viewModel.pendingWorkspaceApproval {
                WorkspaceToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingWorkspaceTool()
                    },
                    onDeny: {
                        viewModel.denyPendingWorkspaceTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if let request = viewModel.pendingIshHandoffApproval {
                    IshHandoffToolApprovalCard(
                        request: request,
                        onApprove: { scope in
                            viewModel.approvePendingIshHandoffTool(
                                requestId: request.id,
                                requestRunId: request.runId,
                                scope: scope
                            )
                        },
                        onDeny: {
                            viewModel.denyPendingIshHandoffTool(
                                requestId: request.id,
                                requestRunId: request.runId
                            )
                        }
                    )
                    .id(request.presentationId)
                    .transition(ishApprovalTransition)
                    .zIndex(2)
                }
            }
            .animation(
                ishApprovalVisibilityAnimation,
                value: viewModel.pendingIshHandoffApproval?.presentationId
            )

            if let request = viewModel.pendingMcpApproval {
                McpToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingMcpTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingMcpTool(requestId: request.id)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingRecipeApproval {
                RecipeToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingRecipeTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingRecipeTool(requestId: request.id)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingCouncilApproval {
                CouncilToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingCouncilTool()
                    },
                    onDeny: {
                        viewModel.denyPendingCouncilTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingAskUser {
                ChatAskUserCard(
                    request: request,
                    onAnswer: { answer in
                        viewModel.answerPendingAskUser(answer)
                    },
                    onSkip: {
                        viewModel.skipPendingAskUser()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge)
                .stroke(AmberTheme.accentAmber.opacity(gateHighlightRequest == nil ? 0 : 0.85), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .task(id: gateHighlightRequest) {
            guard gateHighlightRequest != nil else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { gateHighlightRequest = nil }
        }
    }

}
