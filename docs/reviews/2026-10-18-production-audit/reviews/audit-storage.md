# Storage / workspace / compaction audit

Scope: current working tree at HEAD b98bd6f0, including current untracked Swift split files. Read-only inspection; no builds or tests run by this agent. Reviewed `iosApp/AGENTS.md`, IOSConversationStore and Chat/Storage, DocumentAccessStore and Infrastructure/Workspace, IOSContextCompactionCoordinator and Chat/Compaction. Credentials / settings / backup were delegated narrowly; see `audit-credentials-backup.md`.

## Confirmed findings

### S1 — P2: concurrent branch mutations overwrite a successful edit/deletion

- Owner lines: `iosApp/iosApp/Chat/Storage/IOSConversationBranching.swift:66-95`, `:110-140`, `:156-184`, `:200-225`, `:238-257`. Each operation reads a Conversation, changes a full `messageNodes` snapshot and calls `persist` without `ifUnchangedSince`.
- Reachable production entry: `Chat/Session/ChatConversationMutations.swift:777-821` starts independent Tasks for delete/select. The guards exclude generation, vision and Intelligent UI submissions, but do not reserve a branch mutation while its asynchronous storage write is pending. Large conversations / slow I/O let another branch action enter while the first still awaits `storage.saveConversation` and before `currentConversation` has advanced. A send can similarly advance the transcript while a branch save is pending.
- Concrete trigger: start from nodes `[A, B, C]`; first delete captures `[B, C]` and suspends; second delete captures the still-current original snapshot and persists `[A, C]`; first stale write later persists `[B, C]`. Both return success; B is resurrected. Reversing write order resurrects A instead. Two independent variant selections can similarly lose one selection. This is durable transcript corruption, not just delayed UI.
- Second review / false-positive exclusion: MainActor prevents simultaneous Swift execution but permits reentrancy at the storage await. `beginConversationWrite` only counts in-flight writes for restore; it is not a mutex. Import epoch protects restore ownership only. `writeSequences` protects only callers that actually supply a baseline. Existing KMP storage mutex serializes individual disk writes, but cannot merge stale snapshots. The KMP audit owner independently confirmed `saveConversation` merges metadata only, and writes incoming `messageNodes` in full (`JsonConversationStorage.kt:166-196`, `:349-378`). This agent did not inspect KMP source itself.
- Minimal regression seam: reuse `IOSConversationStore.beforePersistForTesting` from `IOSConversationStoreConcurrencyTests`. Pause only the first `deleteMessage(messageIndex: 0)` after its snapshot is constructed; execute and await a second delete or append/select action; release the first; assert a newer successful action is never overwritten, including after constructing a restarted store. Also cover a delayed branch mutation versus `save(messages:)` and verify old conversation ownership remains intact after switching the UI.
- Minimal repair direction: make branch snapshot commits participate in the existing per-conversation baseline guard, capturing before the first read. If a newer mutation invalidates a user branch action, return a user-visible conflict/retry state (do not silently claim success). If choosing serialization instead, keep it scoped to the branch owner and preserve the original message identity across shifted indices. Do not add generic retries or a new persistence framework.
- Existing tests: IOSConversationStoreBranchingTests cover normal branch paths, conversation switching and deletion interruption; IOSConversationStoreConcurrencyTests cover explicit stale baselines and background retry. No current test exercises two branch mutations racing.

### S2 — P2: PPTX numeric slide sorting never extracts a number

- Owner lines: `iosApp/iosApp/DocumentAccessStore.swift:797-807`, consumed at `:508-519`.
- Reachable production entries: chat file picker `Chat/Composer/ChatViewAttachmentImport.swift:34-46`; Workspace import through `Infrastructure/Workspace/IOSWorkspaceStore.swift:251`, `:1301`; DeepRead picker `DeepReadCreateView.swift:1223-1227`; Board picker and Council source materials use the same reader.
- Concrete trigger: a valid PPTX ZIP central directory contains `ppt/slides/slide1.xml`, `ppt/slides/slide10.xml`, `ppt/slides/slide2.xml` (normal archive ordering may be lexicographic). `trailingInt` reverses the entire filename, so its first character is `l` from `.xml`; the numeric prefix is empty and every slide gets sort key 0. The emitted `[Slide 1]`, `[Slide 2]`, `[Slide 3]` sections therefore follow the archive order and place slide10 before slide2. The context supplied to the model has the wrong reading order and wrong displayed numbers.
- Second review / false-positive exclusion: the code explicitly promises numeric ordering in its documentation; `.sorted` compares equal keys for every normal slide. File existence, permissions and grant behavior do not alter this calculation. The function is on the default supported PPTX import route.
- Minimal regression seam: reuse `DocumentAccessStoreTests.makeStoredZip`, adding three slide XML entries in the order slide1 / slide10 / slide2. Read via the public selected-file executor or `previewFileForWorkspace`. Assert output text order is slide1 / slide2 / slide10 and numbered sections agree. No production testing seam is needed.
- Minimal repair: strip the extension / inspect the last path component's stem before extracting trailing digits. Keep scope on the existing numeric-order contract. Actual PowerPoint custom presentation order is stored in `presentation.xml` + relationships; implementing that is separate format support and is not needed for this repair.
- Existing tests: DocumentAccessStoreTests exercise stored DOCX/text/PDF and workspace persistence; no PPTX order regression was found.

## Excluded / by design / not elevated

- `appendDeepReadResultToCurrentConversation` returns true without propagating save failure, but no production caller exists in the current tree (only its declaration and persistence test); excluded as dead-path cleanup, with no deletion proposed.
- Branch `deleteMessage` removes the whole node, including siblings. Its current contract is explicit in the implementation comment and ViewModel action naming; not reported as per-variant deletion failure.
- Workspace proposed writes/edits parse staged payloads, verify the original record and bytes after awaiting, then persist with rollback on metadata failure. Reparse verifies the original record before updating it. These paths already address the straightforward stale read-modify-write and payload/metadata mismatch candidates.
- Selected-file reads verify the grant id again after asynchronous parsing, so a replacement grant cannot acquire the previous file's result. Chat picker also has its own exclusive processing owner. No grant ownership defect is claimed here.
- Compaction validates ancestor coverage against source message identities, cancels active compaction on deletion, and checks cancellation before disk commit. No new production compaction defect was established within this review.
- XML entity decoding's sequential replacements can double-decode escaped literal entities in Office text. This is a smaller separate formatting candidate observed during inspection; per root's stop-scan instruction it was not expanded or included among repair findings.

## Suggested phase placement

1. Credentials/settings transaction fixes from `audit-credentials-backup.md`, with injected Keychain failure tests.
2. Branch snapshot ownership fix and deterministic stale-write regressions; then storage/concurrency/branch suites plus independent subagent review.
3. Numeric PPTX sorting fix and public-import regression; run DocumentAccessStoreTests; then independent subagent review.

No file outside this report was modified by this agent.
