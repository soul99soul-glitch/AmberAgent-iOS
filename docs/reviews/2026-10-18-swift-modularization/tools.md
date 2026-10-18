# Tool / execution / orchestration architecture review

Scope: read-only review of eight production Swift files in `/Users/arquiel/Downloads/AI/amberagent-ios`. Read `iosApp/AGENTS.md`; no source files changed, no builds/tests executed. Line counts measured on current working-tree contents using Python `splitlines()`. This is an architecture/refactor assessment, not a claim that large files contain a newly reproduced functional bug.

## Confirmed production reachability

- `AppShell.swift:70` and `IOSChatBackgroundGenerationCoordinator.swift:849` instantiate `IOSLocalToolExecutor`.
- `ChatRunKernelAdapter.swift:262`, `IOSChatBackgroundGenerationCoordinator.swift:2487`, `SubAgentRunner.swift:428`, `IOSDeepReadSynthesisRunner.swift:18`, `NovelCreation/NovelLiveModelAdapter.swift:1130` consume `IOSAgentToolEngine`.
- `ChatViewModel.swift:1067` composes `IOSThreadOrchestrationToolService`; its own dispatch is `:313`.
- `ChatToolRuntime.swift:435` owns chat `CouncilRunner`; `CouncilChatRuntimeView.swift:1895` owns the formal `IOSCouncilRoomRunner`.
- `IOSSearchToolDispatch.swift:69,101`, DeepRead source collection, `BoardView.swift:615` and `CouncilRunner.swift:570,602` consume search.
- `IOSDynamicToolRegistry.swift:258,293`, `ChatToolRuntime.swift:622`, `RecipesView.swift:152,208` consume recipe storage.

## Six architectural conclusions

1. **Largest file is chiefly a misplaced subsystem, not an 8429-line executor class.** `IOSLocalToolExecutor.swift:141–1154` contains a roughly 1014-line executor. `:1156` begins WebMount core, containing registry/settings, URL policy, cookie store, WK runtime, injected JS, session store, tool controller, redaction and support models. Moving complete existing owners to a `WebMount/` directory yields a large safe improvement before changing behavior. `IOSWebMountWKRuntime` (`:2065–3234`) and `IOSWebMountBridgeScripts` (`:3241–4288`) each already fit under 1500 once physically separated. This strongly supports responsibility-based extraction over arbitrary 1000-line extensions.

2. **A few true large coordinators remain after moving independent types.** WebMount controller (`IOSLocalToolExecutor.swift:5304–8163`, approximately 2860 lines), orchestration service (`IOSThreadOrchestrationToolService.swift:52–3014`), council room runner (`CouncilRunner.swift:1105–2730`) and engine class (`IOSAgentToolEngine.swift:684–2574`) combine lifecycle sequencing with distinct policies/transports/presentation. Here merely moving `private` methods into extensions broadens access and leaves the same coupling. Extract concrete operation/policy collaborators and preserve the current owner of run/session state.

3. **Networking policy currently has the wrong domain owner.** `IOSSearchExecutor.swift:1255–1346` owns URL/public-address validation and DNS resolution, yet WebMount URL policy and navigation (`IOSLocalToolExecutor.swift:1780,1848,2163,2188,5339`), WebMount public DNS (`IOSWebMountPublicDNS.swift:160`), MiniApp (`IOSMiniAppBridgeRuntime.swift:914`, `IOSMiniAppDeviceCapabilities.swift:296`, `MiniAppRunnerWebView.swift:787`), Watch (`WatchTaskSnapshotBuilder.swift:450`) and ChatToolRuntime (`:4402–4414`) use it. Conversely search transport defaults to `IOSWebMountPublicDNS.resolve` (`IOSSearchExecutor.swift:79`). A small `Networking/IOSPublicURLPolicy.swift` plus DNS owner is justified by current cross-domain consumers. Preserve the distinction between strict public transport and the verified scrape-only Fake-IP route; do not consolidate them into a permissive universal fetcher.

4. **An unrelated shared task store is hidden inside terminal runtime.** `IOSTerminalRuntime.swift:235–626` defines advanced task kind/status/record/persistence used by council and subagents, while `:820–1423` owns actual terminal jobs. Pull `IOSAdvancedTaskModels.swift` and `IOSAdvancedTaskStore.swift` into the existing runtime/task domain, independent of terminal. Its own UserDefaults key, bounded retention and startup interruption rules remain unchanged. This removes a real discoverability/dependency issue without inventing an abstract job framework.

5. **Recipe storage already has two distinct artifact owners plus trust/health policy in one file.** The recipe store occupies `IOSRecipeFileStore.swift:105–703`; plugin trust/archive begins `:707`, health begins `:885`, directory policy `:1079`, plugin store `:1189`. Existing independent types can simply become files. Keep recipe/plugin hash and transactional publish semantics separate; do not use line-cap work to introduce one generic artifact repository. The leading comment at `:6–9` saying no second artifact kind exists is stale relative to the plugin types below, but that alone does not justify merging the implementations.

6. **There are useful existing boundaries and unusually consequential invariants worth retaining.** Search has injected `IOSSearchHTTPTransport` (`:51`), WebMount has `IOSWebMountRuntimeServicing` (`IOSLocalToolExecutor.swift:2017`) and independent `IOSWebMountSessionStore` (`:4486`), terminal injects SSH/embedded backends (`IOSTerminalRuntime.swift:747–770,830`), council injects researcher/streamer (`CouncilRunner.swift:523,635,1115`), engine injects text provider/executors (`IOSAgentToolEngine.swift:72,107,725`), orchestration injects scheduling and DAOs (`IOSThreadOrchestrationToolService.swift:90,198–240`). Existing behavioral tests exercise approval, stale snapshot, outcome-unknown, durable writes, late callbacks and cancellation. Refactor around these seams; do not replace them with a new universal executor/service container.

## Per-file split plan

Suggested new file sizes are planning envelopes, not exact estimates after compilation/access-control adjustments. All remain in the existing iOS application target initially; extracting Swift packages/frameworks is a separate decision because Shared.framework, app composition and iOS runtime ownership currently cross these seams.

### 1. IOSLocalToolExecutor.swift — 8429 lines

**First pass: move whole existing types, no logic changes.**

- `Tools/IOSLocalToolExecutor.swift`: current executor plus its execution request/output and permission previews, about 1000–1200 lines. Keep a narrow permission-aware entry point.
- `WebMount/IOSWebMountModels.swift`: site/auth/runtime/session DTOs and errors; 350–600 lines. Keep internal persistence metadata beside `SessionStore` if no other user needs it.
- `WebMount/IOSWebMountRegistry.swift`: registry plus settings/store (current 1429–1676); 250–400 lines.
- `WebMount/IOSWebMountURLPolicy.swift`: WebMount-specific allowed-host/user-navigation policy (current 1677–1874); 200–300 lines, depending on shared DNS extraction.
- `WebMount/IOSWebMountCookieStore.swift`: current 1875–1978; roughly 110 lines.
- `WebMount/IOSWebMountWKRuntime.swift`: current 2064–3239; roughly 1180 lines. Keep navigation, pending load continuation and WK delegates together.
- `WebMount/IOSWebMountBridgeScripts.swift`: current 3241–4288; roughly 1050 lines. Embedded JS is code but not a reason to change runtime loading to bundled resources in this refactor.
- `WebMount/IOSWebMountSessionStore.swift`: current session metadata and 4484–5148; roughly 800 lines.
- `WebMount/IOSWebMountScreenshotArtifactStore.swift`: current 5150–5246; roughly 100 lines.
- `WebMount/IOSWebMountRedactor.swift`: current 8165 onward redaction/support; roughly 260 lines (clock/host resolver aliases can go to relevant models).

**Second pass: actually decompose controller, currently 5304–8163.**

- `IOSWebMountController.swift`, target 700–1100: public facade, dispatcher, session resolution/agent binding, top-level policy and result envelope, station/session/memory management.
- `IOSWebMountLocalCommands.swift`, target 900–1200: local open/read/observe/get/screenshot/act command execution and before/after observation semantics. Keep per-session agent observation bookkeeping with this concrete owner if extracted; do not duplicate it between facade and handler.
- `IOSWebMountDesktopCommands.swift`, target 800–1100: remote session creation/reconnect/routing, validated remote URL, desktop result receipts. Reuse existing desktop adapter; do not create a second MCP client abstraction.
- Catalog may be a small `IOSWebMountToolCatalog.swift` or stay with facade; it does not require a standalone protocol.

**Ownership / risks:** `IOSWebMountSessionStore` remains the sole owner of runtimes, lease/control owner, metadata and visible current session (`:4492–4511`). `IOSWebMountWKRuntime` remains `@MainActor`, sole owner of pending-load continuation, navigation sequence and WKWebView (`:2068–2183`). Preserve sessionId + runId + conversationId binding, post-await revalidation, permission snapshot scope/payload hashes, user takeover, outcome-unknown receipts, redaction, popup policy and timeout completion. Extract concrete collaborators so `private` state does not become widely `internal` merely to enable cross-file extensions.

**Verification:** `IOSLocalToolExecutorTests`, `IOSWebMountAutomationContractTests`, `IOSWebMountRuntimeEvidenceTests`, `IOSWebMountOutputBudgetTests`, `IOSWebMountFakeIPTests`, `IOSWebMountPublicDNSTests`, `IOSWebMountVisionReaderTests`, `IOSJevWebMountLoopTests`. Important existing assertions: takeover during in-flight mutation (`IOSLocalToolExecutorTests.swift:2001`), action sequence/navigation abort (`:2098,2187`), ownership change during postcondition (`:2666`), persistent session restoration (`:2715`), TTL/card ownership (`:2778,2818`), approval baseline conflicts (`:2976,3019`). Simulator WK tests then real browser/user handback smoke test; mocks alone do not establish WK permission/visual correctness.

### 2. IOSAgentToolEngine.swift — 2574 lines

Suggested `AgentRuntime/ToolEngine/`:

- `IOSAgentToolContracts.swift` (outcomes, executor/provider protocols, results/approval/mailbox immutable projections; ~300 lines).
- `IOSAgentProviderAdapter.swift` (shared KMP providers and `OpenAIKmpProviderAdapter`, currently 151–346; ~200 lines).
- `IOSAgentProviderStep.swift` (prepared request, streaming/blocking/Grok/Gemini step orchestration plus `StreamStepState`; ~650–900 lines).
- `IOSAgentToolBatchExecutor.swift` (pending/pre-existing batch, durable prepare/start/terminal, output replay/application; ~600–800 lines).
- `IOSAgentToolEngine.swift` (run loop, guard finalization and existing public facade; ~900–1200 lines).

**Ownership / risks:** the engine remains one run at a time. It owns the executor registry and next-round replacement; batch consumes the active round registry without introducing a second mutable cache. `working`, effective params and `IOSToolLoopGuard` remain run-local (`:1316–1326`), not shared with subsequent runs. Keep `StreamStepState`'s NSLock, single-resume continuation/Kotlin job/cancel owner together (`:457–478`); do not casually add actors around non-Sendable KMP message types. Preserve prepare-before-durable-request-snapshot, pre-existing tools before first provider request, strict argument parsing before side effects, PREPARED/STARTED/terminal order, stop on unknown/write failure, approval batch barrier and final citation flush. Existing `@unchecked Sendable` requires ownership inspection, not a blind concurrency annotation migration.

**Verification:** `IOSAgentToolEngineTests`, `IOSAgentToolEngineKernelHookTests`, applicable foreground/background kernel tests and provider adapter tests. Concrete fixtures already cover request snapshot failure (`Tests:769`), partial stream/error/cancel tails (`:1555,1571`), replay (`:1916`), handback batch barrier and terminal write failure (`:1958,2003,2114`); keep provider routing and Swift/KMP consumption tested. Build all Swift consumers because engine is shared by chat/background/subagent/DeepRead/novel.

### 3. IOSThreadOrchestrationToolService.swift — 3045 lines

Suggested `AgentRuntime/Orchestration/`:

- `IOSOrchestrationModels.swift`: configuration marker DTO, immutable edge/pending snapshots, result/error types (~200–300).
- `IOSOrchestrationLaunchPolicy.swift`: argument/role/skill/model/reasoning resolution and child upload prompt (~450–650; current 1181–1635).
- `IOSOrchestrationJevRouting.swift`: Jev batching, observed/shadow routing metrics, selected pool linkage (~500–650; current 710–1180).
- `IOSOrchestrationPersistence.swift`: DAO async bridges and typed target/edge/mailbox access (~300–500). Keep Room entities inside callbacks and project Sendable values there.
- `IOSOrchestrationRunLauncher.swift`: durable child startup/handoff and occupancy reservation (~250–400); reuse `BackgroundScheduling`.
- `IOSThreadOrchestrationToolService.swift`: API dispatch, spawn/list/interrupt, coordinated followup/terminal resume (~1100–1400 after extraction).
- If service still exceeds 1500, `IOSOrchestrationMailboxCommands.swift` owns send/wait/terminal envelope formatting (~450–650), **but the per-child followup gate and active-check→enqueue→start transaction stay with one coordinator**, shared by followup and terminal resume. No independent per-tool gate copies.

**Ownership / risks:** service currently owns `inFlightBootstrapCount`, `inFlightFollowupTargets` and continuation waiters (`:212–221`) and `modelPool` (`:236`). Preserve synchronous MainActor capacity check plus reservation with no intervening await, release on all failure paths; retain model reservations in one model-pool owner. Service coordinates real persisted conversation/edge/mailbox/run owners, not a separate in-memory truth. Preserve run-bound conversation rather than current UI selection, fork/JS-cell copying, explicit scope/model inheritance, active vs idle followup behavior, FINAL_ANSWER idempotence and durable payload before scheduler start (`:2516–2613`). Never convert these into fire-and-forget independently owned tasks as a side effect of splitting.

**Verification:** `IOSOrchestrationToolTests` plus existing mailbox/background/foreground tests. Essential current tests: edge failure prevents child/start (`:294`), concurrent capacity (`:809`), dynamic pool (`:901`), shadow timing/revision (`:1137,1274`), run-bound conversation (`:1867`), idempotent terminal delivery (`:1954`), start failure reclaims running row (`:2023`), persisted scope for followup (`:2340`). Regression must include parallel followup vs terminal resume and canceled wait; if absent, add targeted behavioral coverage before extracting that transaction.

### 4. CouncilRunner.swift — 3031 lines

Suggested `Council/`:

- `IOSCouncilSettings.swift`: configuration/presets/normalization (1–231) and observable settings store (232–353), ~350.
- `IOSCouncilRunModels.swift`: request/events/summary/research DTOs (355–522), ~170.
- `IOSCouncilResearcher.swift`: injected researcher + search implementation (523–633), ~115.
- `IOSCouncilTextStreamer.swift`: stream protocol, active stream, text presentation, tail and heartbeat (635–1091), ~460. Presentation can become its own file when needed; no requirement to do so now.
- `IOSCouncilModelRouting.swift`: route resolution, dynamic seat planning/parser/probe (1909–2188,2289–2392), ~400–550.
- `IOSCouncilPrompts.swift`: prompt construction, output sanitization, transcript format/digest (2393–2744), ~350–450.
- `IOSCouncilRoomRunner.swift`: lifecycle, round execution and terminal result (~950–1200 after extracting above; current run function 1176–1907 still deserves extraction into named stages where state ownership stays clear).
- `CouncilLiveModel.swift`: observable message presentation and registry (2765–2900), ~140.
- `CouncilRunner.swift`: chat tool facade (2901–3031), ~135.

**Ownership / risks:** formal room runner owns runGeneration/activeTaskId and injected streamer (`:1105–1113`); ViewModel owns page/background lease lifecycle, as documented by `markActiveTaskTerminal` (`:1152–1174`). `IOSAdvancedTaskStore` owns durable records; `CouncilLiveModel` is only UI projection. Preserve old-run callbacks, cancellation, heartbeat silence timeout (not total elapsed duration), partial seat failure vs overall success, continuation preserving prior completed answer (`:1829–1907`), research consent and stream tail flush/drain. Do not make a second lifecycle coordinator while splitting prompt/route/presentation code.

**Verification:** `IOSCouncilRunnerMechanicsTests`, `IOSSharedSettingsStoreCouncilSeatTests`, `CouncilSourceMaterialsTests`, archive tests and associated background coordinator tests. Existing mechanics assertions cover background/continuation/task identity and input consent; real provider streaming + background expiration require separate device evidence after behavior-preserving extraction.

### 5. IOSTerminalRuntime.swift — 2642 lines

Suggested split:

- `Terminal/IOSTerminalModels.swift`: capability/build policy/tool catalogs and job snapshots (1–234), ~235.
- `Tasks/IOSAdvancedTaskModels.swift` and `Tasks/IOSAdvancedTaskStore.swift`: current 235–627, ~90 + 310 (or one ~400-line file if project grouping prefers).
- `Terminal/IOSTerminalCommandPolicy.swift`: command validation and POSIX quoting (628–744), ~120.
- `Terminal/IOSTerminalRuntime.swift`: SSH/embedded protocols, live job state and runtime incl embedded extension (747–1423), ~680. Keep one jobs dictionary, do not create a job manager for each runtime.
- `Terminal/IOSRemoteTerminalExecuteExecutor.swift`: one-shot SSH request/preview/dispatch + error (~245).
- `Terminal/IOSAmberShellExecuteExecutor.swift`: one-shot shell request/preview/dispatch + error (~200).
- `Terminal/IOSAgentTerminalJobExecutor.swift`: start/read/wait/stop + result encoding and job errors (1827–2552 plus error), ~760.

**Ownership / risks:** `IOSTerminalRuntime.jobs` and tasks remain MainActor-owned (`:820–828`), `IOSAdvancedTaskStore` durable projections stay separate; read/wait must not destructively consume or cancel a job, stop remains idempotent. Preserve canonical working-directory quoting, approval target/profile digest binding, output truncation/redaction and stdout/stderr distinction; cancellation/late backend completion must not overwrite terminal status. Stable/experimental runtime linkage remains unchanged.

**Verification:** `IOSSSHRuntimeTests`, `IOSSSHCredentialTests`, `IOSEmbeddedIshJobRuntimeTests`, `IOSLocalToolExecutorTests`; key tests include late completion (`SSHTests:360`), observer wait timeout/cancel (`:384,402`), task restore/stop idempotence (`:488`), approved target drift (`:655`). Link/build stable and experimental targets when affected. Live SSH/iSH smoke checks are distinct from mocks.

### 6. IOSWebMountDesktopBackend.swift — 2003 lines

Suggested `WebMount/Desktop/`:

- `IOSWebMountDesktopModels.swift`: backend status/capability/errors and endpoint policy (1–181), ~180.
- `IOSWebMountDesktopMapping.swift`: tool descriptor/capabilities + argument mapping (724–1063), ~400–500.
- `IOSWebMountDesktopSemantics.swift`: semantic element/page identity, parser/normalizer + action disposition/redaction (182–262,1064–1283,1319–1600,1751–1937), ~700–900, pure value-based decisions.
- `IOSWebMountDesktopBackendAdapter.swift`: connections, snapshots, connect/execute/preflight/close and receipts, ~800–1100.
- `IOSWebMountRemotePlaceholderRuntime.swift`: current 1954–2003, ~50; can live with models if a separate tiny file would add no value.

**Ownership / risks:** adapter exclusively owns connections, snapshot IDs/elements/page identity/revisions/status (`:307–320`), all `@MainActor`. Extract pure mapping/semantics with an immutable snapshot passed in, not a second snapshot cache. Preserve fresh-snapshot refresh before mutation, remote schema-advertised mapping rather than guessing APIs, pre-dispatch rejection vs post-dispatch unknown, timeout/cancellation, remote URL provenance and user-control takeover.

**Verification:** `IOSWebMountDesktopBackendTests`, local WebMount integration suites. Specific existing coverage: stale semantic reference (`:465,1029,1056`), wrong gateway mapping (`:433,865`), precondition before dispatch (`:1267`), RPC unknown after dispatch (`:914,994`), takeover during snapshot/in-flight (`:1423,1427,1500`). Real MCP backend is a separate acceptance gate.

### 7. IOSSearchExecutor.swift — 1502 lines

At 1502 lines this file needs only a small responsibility extraction to meet the cap; do not force a huge provider architecture because it is two lines over.

Recommended minimum useful split:

- `Networking/IOSPublicURLPolicy.swift`: currently 1255–1346 public URL/IP/DNS operations, ~100–150. Migrate actual cross-domain consumers in a focused batch, preserving strict-vs-verified-scrape distinction. DNS resolver itself may be a small separate `IOSHostResolver` only if it improves clear dependency direction.
- `Search/IOSSearchHTTPTransport.swift`: transport interface, URLSession and bounded loader (51–268), ~220–260.
- `Search/IOSSearchExecutor.swift`: current dispatch/provider routing/providers/scrape/format/error/models, remaining ~1150–1250. This already satisfies 1500 and preserves current entry point.

Optional next-step only if changes demonstrate repeated missed edits: extract `IOSSearchProviderSelection` rules and provider adapters (~431–773) or HTML parsing (~810–853,977–1001,1356–1449). No need to introduce one class per HTTP provider merely for symmetry.

**Ownership / risks:** executor is mostly stateless; transport owns network cancellation/redirect/body limits, and shared policy defines accepted URLs/addresses. Preserve provider-selection fallback reason and saved credentials, API-key behavior, public DNS/fake IP route, redirects, response cap, cancellation without fallback, image metadata. MainActor transport requirement is existing behavior; do not change concurrency model as part of moving files.

**Verification:** `IOSSearchExecutorTests`, `IOSFreeSearchAggregatorTests`, `IOSWebMountPublicDNSTests`, `IOSWebMountFakeIPTests` and MiniApp URL policy callers if redirected to new owner. Relevant tests: provider media (`SearchTests:289,315`), cancellation no fallback (`:370`), private DNS (`:531`), strict fake IP rejection vs verified resolver (`:549,571,580,596`), cancellation/deadline (`:612,638`). Search provider live HTTP acceptance remains separate.

### 8. IOSRecipeFileStore.swift — 1787 lines

All can be split by existing concrete owner with little semantic change:

- `Recipes/IOSRecipeFileStore.swift`: recipe package/receipts/store/errors (1–703), ~705.
- `Plugins/IOSPluginArchiveCodec.swift`: trust records, archive envelopes/codec (707–873), ~170.
- `Plugins/IOSPluginHealthStore.swift`: health models/transitions/store (885–1078), ~195.
- `Plugins/IOSPluginDirectoryPolicyStore.swift`: directory reports/policy store (1079–1157), ~80.
- `Plugins/IOSPluginFileStore.swift`: package/preparation/receipt and file store/errors (874–884,1158–1787), ~650.

**Ownership / risks:** recipe and plugin stores retain their static mutation locks (`:108,:1190`), same-volume staging and atomic publish, candidate/base hash CAS and rollback validation. Do not move lock ownership to per-instance helpers. Archive codec owns signature/trust validation; health store owns cache/journal/quarantine; directory policy owns local block/report. Preserve package IDs/path traversal checks, explicit enable after permission/trust expansion, canonical hashing and persisted directory layout/UserDefaults/data formats; no migration is required for file splitting.

**Verification:** `IOSRecipeIntegrationTests`, `IOSPluginCommandTests`, `IOSPluginJSONSchemaTests`, `IOSDynamicToolRegistry` hot reload behavior; existing critical tests cover zero-write path validation/permission expansion (`RecipeTests:294`), quarantine journal failure (`:538`), signed archive tampering/trust downgrade (`:969`), archive traversal (`:1085`), stale candidate/base (`:1476,1524`), pinned lease after new promotion (`:1423`). No existing assertion should be weakened to make the split pass.

## Recommended sequencing for this domain

1. Baseline affected test/build commands and line-count inventory; agree production + test + first-party extension sources are measured, generated/vendor handled explicitly by root plan.
2. Low-risk complete-type moves: recipe/plugin, terminal/advanced task store, council settings/models/streamer. Complete the shared public URL policy extraction with all real consumers updated before moving WebMount's URL-policy consumers; keep provider settings + Shared.framework boundaries stable.
3. Move WebMount registry/policy/runtime/scripts/session store as complete types after the shared networking policy batch. This follows phase 2 of the consolidated plan and avoids concurrent edits to the same files.
4. Controller decomposition: WebMount local/desktop commands, desktop pure mapping/semantics, council route/prompt separation. Review access-control changes for accidental public/internal expansion.
5. Highest-risk sequencing owners last: engine provider-step/batch extraction; orchestration launch/Jev/DAO extraction with followup/resume gate intact.
6. For each owner batch run focused behavior tests then app build; run associated integration gates at domain boundary. A final fresh inventory must show every in-scope Swift file <=1500; tests and their shared fakes must also be split by behavior without changing discovery/fixture lifecycles. Avoid an arbitrary target of exactly 1500; use about 1000–1200 for remaining coordinators to leave practical headroom.

No recommendation here requires new framework targets, a generic workflow engine, blanket dependency injection, or a concurrency model migration. Those would change scope and cost substantially without being necessary to solve the demonstrated organization problem.
