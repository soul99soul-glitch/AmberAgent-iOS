# Phase 1 storage / document / credential repairs

Status: root confirmed the targeted red tests failed for their intended causes. All four production fixes (S1/S2/CRED-1/CRED-2) are complete and frozen, awaiting root's unified green run. Credential implementation details and selectors are recorded in `phase-1-credentials.md`.

Ownership: this agent owns IOSConversationStore message snapshot/branch coordination, Chat/Storage/IOSConversationBranching.swift and directly related send guards/tests, plus DocumentAccessStore.swift/tests. Credentials child agent owns IOSSharedSettingsStore.swift, ProviderDetailView.swift, IOSProviderConfigToolService.swift and credential tests. All pre-existing WIP is retained; no tests or files were deleted.

## Red tests delivered to root

- `iosAppTests/IOSConversationStoreConcurrencyTests/testSecondBranchMutationIsRejectedWhileFirstReservedWriteIsSuspended`
- `iosAppTests/IOSConversationStoreConcurrencyTests/testBranchMutationDoesNotRaceAReservedForegroundSave`
- `iosAppTests/IOSConversationStoreConcurrencyTests/testForegroundSaveIsRejectedWhileBranchMutationOwnsConversation`
- `iosAppTests/IOSConversationStoreConcurrencyTests/testSendDuringBranchSavePreservesComposerDraftForRetry`
- `iosAppTests/DocumentAccessStoreTests/testPptxSlidesAreReadInNumericOrderInsteadOfArchiveOrder`
- `iosAppTests/IOSModelCredentialTransactionTests` (new file; root owns Xcode project generation).

One DEBUG hook was added after the message write sequence reservation, immediately before storage.saveConversation, so the tests cover the real reentrant in-flight window instead of only the easier pre-reservation baseline check. Root's `/tmp/amber-audit-20261018-current/phase1-red-summary.json` confirms all four S1 tests, the PPTX test and the three failing credential transaction tests failed; the successful credential deletion control passed. The PPTX expectation was subsequently corrected to match the pre-existing flat preview format while retaining the exact numeric-order assertion.

## Implemented focused repairs

- S1: bounded per-conversation branch ownership; competing branch mutations and snapshot saves return a visible retryable busy result. A snapshot write that already reserved its save also blocks a new branch mutation. The normal send path checks before consuming its composer draft. No asynchronous lock, queue, retries, or index replay is introduced. Metadata partial updates retain their current ownership.
- S2: extract numeric suffix from the PPTX path stem, preserving the existing numeric ordering contract. Custom presentation order support stays outside this repair.
- CRED-1/CRED-2: rely on restoreSnapshot as the credential transaction owner, guard its failure return, and avoid deleting old credential references before it commits. Relevant callers retain editing state and display the existing persistence error.

## S1/S2 changed paths and verification

- `iosApp/iosApp/IOSConversationStore.swift`: two per-conversation ownership collections; ordinary save keeps its snapshot-write count through state publication; persist respects branch ownership and tracks its own in-flight window; one DEBUG reservation seam. Current file is 1496 lines.
- `iosApp/iosApp/Chat/Storage/IOSConversationBranching.swift`: branch actions own their read/write/current-publication interval and reject competing actions with the existing visible error channel. Snapshot counts make an already-started foreground write block a branch action. No metadata serialization was added.
- `iosApp/iosApp/Chat/Session/ChatConversationMutations.swift`: send, card submission, image edit and branch UI entry points query the same store ownership before mutating state. Busy send retains the draft. No second ViewModel ownership field was added.
- `iosApp/iosApp/DocumentAccessStore.swift`: numeric PPTX suffix reads the basename without its extension.
- `iosApp/iosAppTests/IOSConversationStoreConcurrencyTests.swift` and `DocumentAccessStoreTests.swift`: the five regressions above, including retained data after restart and successful retry after the first branch operation completes.

One finite maintainability pass was completed using code-simplifier's Swift guidance. It stayed on the new owner boundaries and caller effects; no unrelated refactor was added. `git diff --check` passed for the owned tracked source/test paths. No worker build/test command was executed.

Suggested green suites: `iosAppTests/IOSConversationStoreConcurrencyTests`, `iosAppTests/IOSConversationStoreBranchingTests`, `iosAppTests/IOSConversationStorePersistenceTests`, `iosAppTests/DocumentAccessStoreTests`; credential selectors are in `phase-1-credentials.md` when the child completes.

No agent in this subgroup runs builds or tests; root owns red, green and final integration commands.
