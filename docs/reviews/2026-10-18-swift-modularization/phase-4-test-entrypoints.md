# Phase 4 XCTest entry points

Original suites now span the following responsibility classes. Selecting only an original class runs a subset. Shared support/base classes contain no test methods.

| Original suite | Original methods | Current selectors (iosAppTests/) |
|---|---:|---|
| `IOSNovelProjectToolExecutorTests` | 37 | `IOSNovelProjectToolAssemblyTests`, `IOSNovelProjectToolExecutorTests` |
| `NovelCollaborationModeTests` | 56 | `NovelChapterPlanProposalTests`, `NovelCollaborationModeTests`, `NovelGhostwriteGenerationTests`, `NovelGhostwriteInjectionTests`, `NovelGhostwriteRecoveryTests` |
| `NovelContinuityAuditTests` | 38 | `NovelContinuityAuditTests` |
| `NovelContinuityAuditViewModelTests` | 4 | `NovelContinuityAuditViewModelTests` |
| `NovelCreationPresentationTests` | 51 | `NovelCreationActionPresentationTests`, `NovelCreationPresentationTests`, `NovelCreationProjectPresentationTests` |
| `NovelCreationViewModelTests` | 56 | `NovelCreationQuickStartTests`, `NovelCreationSyncAndRecoveryTests`, `NovelCreationViewModelTests`, `NovelCreationWorkspaceMutationTests` |
| `NovelFactTransactionLifecycleTests` | 39 | `NovelFactTransactionLifecycleTests` |
| `NovelGenerationLifecycleTests` | 55 | `NovelGenerationLifecycleTests` |
| `NovelGenerationReducerTests` | 36 | `NovelGenerationReducerTests` |
| `NovelLiveModelAdapterTests` | 32 | `NovelLiveModelAdapterTests` |
| `NovelManualEditSyncTests` | 23 | `NovelManualEditSyncTests` |
| `NovelSessionReplayTests` | 53 | `NovelSessionFollowPolicyTests`, `NovelSessionReplayTests`, `NovelSessionRowActionTests`, `NovelSessionTranscriptProjectionTests` |
| `NovelSessionViewModelTests` | 108 | `NovelSessionManualSyncTests`, `NovelSessionQuickStartTests`, `NovelSessionRetryAndPolishTests`, `NovelSessionRunOwnershipTests`, `NovelSessionSelectionTests`, `NovelSessionStreamingPerformanceTests`, `NovelSessionTailPresentationTests`, `NovelSessionViewModelTests` |

All 588 migrated methods require discovery reconciliation with both method maps. The full main Novel scope also contains unchanged suites: 1024 original methods in44 files, plus3 new hosting layout methods. Standalone NovelTests intentionally excludes Amber-only settings presentation and uses its own test settings factory. Actual execution results are recorded in the Phase4 review after integration.
