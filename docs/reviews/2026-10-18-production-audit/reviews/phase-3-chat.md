# Phase 3 — Chat production fixes

Status: full C1–C7 implementation and the three independently identified boundary corrections are frozen for Root green verification. Root owns every build/test run; this agent has not run builds or tests.

## Confirmed red evidence

- `phase3-prep-red-summary.json`: C3–C7 current-API regression suites, 11 tests: 8 expected defects failed, 3 controls passed.
- `pending-domains-red-summary.json`: the original 4 `IOSChatDurableOwnershipTests` failed on the accepted C1/C2 defects; source compiled.
- Additional `testForegroundHandoffStartsCachedContinuationBeforeNextCheckpoint`: added after C2 implementation exposed the remaining normal-handoff adoption boundary. Actual red is confirmed in `boundary-red-and-independent-greens-r2-summary.json`: the hydrated checkpoint did not own an executing continuation. The explicit adoption patch is now implemented.

- `boundary-red-and-independent-greens-r2-summary.json`: the original C1/C2 four regressions plus the added checkpoint-failure regression passed, and all seven detached terminal tests passed. The new cached-handoff regression failed as intended before its fix. Focused final green still remains with Root.

- `phase3-final-boundaries-red-summary.json`: 121 executed, 113 passed and 8 failed. The accepted Chat boundary failures were R1 same-response sequence writes (1), R2 shorter replay / later zero-chunk resume / catch-up publication (3), R3 recovered first-response prefix lost after a following provider failure (1), and the T1 foreground-partial handoff/cancel report boundary (1). The other 2 failures belong to Search test infrastructure. Novel's 90 cases and the original C1/C2 six plus C3 seven and T1 foreground/service controls passed in that run. These actual reds preceded the final corrections below.

- `phase3-phase5-focused-green-summary.json`: 304 executed, 302 passed and 2 failed. R1/R2/R3 and the T1 partial-handoff regressions passed. Two final corrections are now frozen: the Host cached-handoff test must compare against an array captured before live bindings append messages, and the cold-response ledger recovery must retain the freshly read conversation as its read-modify-write merge base. Root/Storage verified the cold-response failure was only the final recovered Tool output assertion; unknown descriptor, ledger status, run status and task-map gate all passed. A rerun remains pending.

## Implementation

C1: `continueCompletedDetachedResponse` checks the original same-run response owner, response identity, persisted task map and absence of a local execution owner. Persist the new continueModel payload before replacing runtimeJob or starting local execution. Generic start dedup remains intact. Duplicate old callbacks reject after mode changes; persistence failure leaves the original response owner available.

C2: the foreground handoff now has an explicit same-run adoption entry for a cached continuation without any execution owner. Generic `start` keeps its old duplicate guard. Ordinary start, response migration and foreground adoption share one persist → runtime replace → remember → execute block, so the old cache remains until persistence succeeds. A cache cannot simply be removed after checkpoint updates because normal `job(for:)` reads hydrate it again; execution ownership is determined from the existing task owners.

A single optional awaited Engine response-completed callback hands canonical working messages through Adapter's existing unchecked-message box to MainActor. Host checkpoints continuation before tools. Upload preparation checkpoints the next round (including completed tool results) and may throw on persistence failure. Session tracks the actual persisted mode/cursor, checks current response identity for detach, and invalidates queued old request callbacks with a provider request token. Payload updates also refresh any hydrated cached runtimeJob without launching it. A checkpoint write failure blocks stale detach and maps to existing recoveryPending behavior; the durable payload is retained. The same runId, ledger and lease stay in use.

R1 correction: same-response sequence progress updates only the live Session cursor/handoff. Only first/new response identity and canonical continuation boundaries persist and refresh the cached runtime. This keeps disk cursor and payload message baseline consistent with event-zero replay and avoids rebuilding the full tool bridge for each stream event. The regression counts the existing persist override, compares hydrated bridge identity, checks the disk sequence remains at its original checkpoint, and verifies the new-response/continue boundaries still update it.

R3 correction: `runDisplayBaseline` is the single immutable message baseline captured from the Host's existing run baseline. Handoff builders, retry/recovery handoffs, the KMP payload codec and runtime hydration carry it separately from current round display/upload. Conversation completion merges, terminal/archive/report projection, live subagent public output, Intelligent UI completion and memory extraction use that original run baseline. Current display remains the source for round accumulation and upload reconciliation. There is no extra conversation write before transfer. Legacy missing/null baseline falls back to the display checkpoint; an explicitly empty baseline remains empty. The actual transfer → second-provider failure regression now reads from a fresh store and checks the recovered first message ID, Text, completed Tool output, and one local error. The existing real Host → cached continuation → adoption test also checks disk/runtime baseline stays at initial harness messages while current display contains this run's completed prefix.

The detached ledger-recovery entry is a distinct transaction: it applies a recovery plan to a freshly read conversation, so its save base remains that exact read snapshot (`messages`). Using the original run baseline there would let a mismatched base drop a newly synthesized unknown Tool. Full terminal merges continue to use `runDisplayBaseline`; the outcome-unknown gate and its complete assertions are unchanged. The Host propagation regression now freezes `originalDisplayBaseline` before `host.start`, preserving all original identity/count/tool-output/adoption assertions while avoiding comparison with mutable live `harness.messages`.

C3: detached failure writer preserves the actual generated suffix from a resumeResponse snapshot, using display count rather than prepared-upload count. Ordinary background paths retain their existing semantics.

R2 correction: runtime construction initializes resumeResponse snapshots with display messages; creating any fresh replay accumulator does not erase a prior partial. The transport delivers all chunks for an event before its checkpoint. The actual accumulator appends those chunks and publishes at the checkpoint through a maximum sequence watermark held under the existing snapshot lock. A replay that has not caught up preserves the earlier message/parts/ID; on catching up, its full snapshot becomes authoritative and new events publish normally. Completion still uses the current accumulator's full result. Three actual-red regressions exercise the same production append/checkpoint entrance, shorter replay failure, later zero-chunk top-level resume, catch-up, subsequent delta and terminal completion. No string-length comparison, delta concatenation across streams or transport mock framework is added.

C4/C5: detached completion uses the same MiniApp failure status mapping and Workspace ordering as normal background completion. Conversation success precedes commit and Workspace synchronization; a failed MiniApp publishes failed, while an applied MiniApp with Workspace warning remains completed and persists the replacement message. Conversation save failure rolls back and does not synchronize Workspace.

C6/C7: raw Markdown reconstruction retains escaped pipes while display-cell decoding is unchanged. Full and incremental scans share the small fence marker/length state and only accept a matching sufficiently long whitespace-only closer.

## Owned paths

Production:

- `iosApp/iosApp/IOSAgentToolEngine.swift`
- `iosApp/iosApp/ChatRunKernelAdapter.swift`
- `iosApp/iosApp/ChatKernelRunHost.swift`
- `iosApp/iosApp/IOSChatBackgroundGenerationCoordinator.swift`
- `iosApp/iosApp/Chat/Generation/Kernel/ChatDurableResponseSession.swift`
- `iosApp/iosApp/Chat/Generation/Kernel/ChatKernelDurableTextProvider.swift`
- `iosApp/iosApp/Chat/Generation/Kernel/ChatRunBackgroundHandoffBuilder.swift`
- `iosApp/iosApp/Chat/Generation/Kernel/ChatRunUploadPreparation.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundResponseResumer.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundPayloadCodec.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundContracts.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundRunState.swift`
- `iosApp/iosApp/Chat/Background/IOSChatBackgroundExecutor.swift`
- `iosApp/iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownBlockParser.swift`
- `iosApp/iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownDetection.swift`
- `shared/src/commonMain/kotlin/shared/IosChatBackgroundPayloadJsonBridge.kt`

Tests:

- `iosApp/iosAppTests/IOSChatDurableOwnershipTests.swift`
- `iosApp/iosAppTests/IOSChatDetachedResponseTerminalTests.swift`
- `iosApp/iosAppTests/ChatMarkdownSourceIntegrityTests.swift`
- `shared/src/commonTest/kotlin/shared/IosChatBackgroundPayloadJsonBridgeTest.kt`

T1 owner coordination: `IOSChatBackgroundTerminalBoundaryTests.swift` supplies the actual foreground-partial → background cancel → callback → parent mailbox regression and explicit original baseline. `IOSThreadOrchestrationToolService.swift` initializes the new child's handoff baseline explicitly from `targetMessages`; its T1 implementation/report is owned separately by the Tools agent.

Pre-existing modularization/WIP in those files has been preserved; do not equate the large HEAD diff with this phase's changes.

## Independent peer review

- Background worker independently reviewed the two Markdown production patches and new renderer tests: PASS.
- Timeline worker independently reviewed C3–C5 and found one blocker: unconditional reconnect snapshot reset. That is fixed within C3; other MiniApp/Workspace contracts passed, with Workspace-warning completed status explicitly confirmed by design.
- Background worker independently reviewed C1/C2 awaited callback, persistence failure/recoveryPending, cursor token, response migration and Swift argument wiring: PASS before the final cached-foreground-handoff adoption addition.
- Root will assign final phase review to an agent that did not implement Chat.
- Root's independent Storage reviewer found R1/R2/R3 and accepted the final owner design. Its final narrow source re-review is PASS with no remaining actionable finding, recorded in `phase-3-independent-review.md`; Root's final green remains pending. Its additional baseline-consumer check identified the live subagent output projection, which now uses the same original run baseline and is asserted within the transfer regression.
- Once-only finite code-simplifier reviews have been performed by the component owners. The main owner's finite final pass checked only this phase's adoption and last three corrected boundaries, preserving all unrelated WIP. Host is 1497 physical lines and Coordinator 1494. No lifecycle constraint comments were removed to meet the existing limit. Owned diff whitespace checks passed.

## Requested validation

Focused suites:

- `iosAppTests/IOSChatDurableOwnershipTests`
- `iosAppTests/IOSChatDetachedResponseTerminalTests`
- `iosAppTests/ChatMarkdownSourceIntegrityTests`
- `iosAppTests/ChatMarkdownRenderingTests`
- `iosAppTests/IOSChatBackgroundTerminalBoundaryTests` (T1 owner)

KMP payload gate (Root also plans the full shared JVM suite and native framework regeneration before compiling the Swift consumer):

```bash
./gradlew :shared:jvmTest --tests shared.IosChatBackgroundPayloadJsonBridgeTest --console=plain
```

Added KMP methods: `encodePersistsRunDisplayBaselineSeparatelyFromDisplayMessages`, `encodePreservesExplicitEmptyRunDisplayBaseline`, and `decodePayloadWithoutRunDisplayBaselineDefaultsToNull`. Native framework task is `:shared:linkDebugFrameworkIosSimulatorArm64`; the new encode label requires rebuilding the framework and its Swift consumer together.

Relevant existing contracts:

- `iosAppTests/IOSChatKernelRunHostTests`
- `iosAppTests/IOSChatKernelRunHostHandoffTests`
- `iosAppTests/IOSChatKernelRunHostPhoneProgressTests`
- `iosAppTests/IOSChatBackgroundExecutionTests`
- `iosAppTests/IOSChatBackgroundStaleSweepTests`
- `iosAppTests/IOSChatBackgroundPhoneActivityTests`
- `iosAppTests/IOSAgentToolEngineStreamingTests`
- `iosAppTests/IOSAgentToolEngineKernelHookTests`

Required native timeline gates from iosApp/AGENTS.md:

- `iosAppTests/ChatSwiftUIStreamReplayTests`
- `iosAppTests/ChatNativeTimelineReplayHistoryTests`
- `iosAppTests/ChatNativeTimelineReplayCompletionTests`
- `iosAppTests/ChatNativeTimelineReplayPerformanceTests`
- `iosAppTests/NativeTimelineScrollCoreTests`
- `iosAppTests/ChatViewportPolicyTests`

Tests use unique run IDs and independent conversation directories; current production writer calls still append those test runs to shared Watch recent history and use the default Room run store, matching existing ExecutionTests. Cleanup never deletes another task map, Watch history or retained conversation data. Real OpenAI responses, process kill, system task expiration and physical-device scrolling/visual behavior have not been manually accepted.
