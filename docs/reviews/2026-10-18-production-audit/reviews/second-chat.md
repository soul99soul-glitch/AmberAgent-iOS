# Independent second review: chat durable ownership

Read current split files and `audit-chat.md`; no product edits, builds, or tests in this second review. Scope was C1/C2 only.

## C1: accepted, P1

`IOSChatBackgroundResponseResumer.swift:149-178` constructs a same-run `.continueModel` handoff after a resumed response finishes with unresolved tool calls. The active `.resumeResponse` runtime job is necessarily still present: `resumeDetachedResponsesIfNeeded` loads it through `job(for:)`, which caches into `activeJobs`, and `resumeDetachedResponse` does not remove it before this transition. `IOSChatBackgroundGenerationCoordinator.swift:367-368` therefore returns true before persistence, replacement, or `startLocalExecution`. The caller then returns without executing tools or finalizing the run. General duplicate-start behavior is reasonable; using it for this mode transition is a real contract violation.

Minimal fix: a named response-to-local continuation transition that checks the expected run/request and original response owner, persists the new continueModel handoff, replaces that exact runtime job, then starts local execution once. Retain generic start deduplication. Do not use `finish` to clear the old job, because that ends run-level ownership and associated leases rather than transferring it. Persistence failure must leave the response checkpoint available to the existing failure/retry route.

Duplicate-tool risk: the existing engine pre-executes unresolved tool parts (`IOSAgentToolBatchExecutor.executePreExistingPendingTools`). Its PREPARED ledger claim returns replay/blocked before reaching the executor (`IOSAgentToolBatchExecutor.swift:198-236`), so preserving the same runId/toolCallId and ledger is essential. Keep `reconcileDetachedResponseLedgerBeforeResume`; do not bypass it or create a new runId during transfer. A narrow transition must reject a second caller once mode is already continueModel or local execution exists.

Regression: install an existing resumeResponse runtime job for the same request, complete with a real unresolved tool part, and assert payload mode changes, local execution begins once, and a counted tool executor executes once. Repeat the transition and assert no second execution. Inject payload persistence failure and verify the old response payload/job remains intact.

## C2: accepted, P1

One ChatDurableResponseSession lives for the whole run. `checkpointPersisted` is set true at `ChatDurableResponseSession.swift:50` and never cleared when its response finishes or a new request starts. Every upload invokes Host.refreshBackgroundHandoff, rebuilding a `.continueModel` handoff with no responseId. Host.detachDurableResponse checks only the old Boolean, then cancels the current stream and clears the foreground owner before invoking the coordinator's recovery of the old persisted response. The provider checkpoint callback being called on every cursor does not prevent the interval before the new response's first callback.

This is reachable through `handoffCurrentGenerationToBackground` (which tries durable detach first), including conversation/background handoff and keepalive expiration. `canHandoffActiveTool` permits model work and pure/networkRead tools; the same runId does not identify a response round. The first response's completed payload stays in the task map/disk unless replaced or removed, so recovery can replay that old response after the second request has begun.

Minimal fix: bind a detachable checkpoint to the current response/request round, invalidate it at the appropriate round boundary, and require a current matching response identity before canceling the foreground owner. Keep the old disk response from remaining a cold-start recovery candidate once ownership has advanced: resetting only the Boolean is sufficient for the live detach branch but leaves the persisted stale owner. Replace/retire that checkpoint through a nonterminal checkpoint transition; `discardDurableResponse` invokes `finish` and must not be reused blindly for the continuing run. Preserve completed tool results in the next upload/display snapshot and retain the same tool ledger. No generic recovery state machine is required.

Regression: run a scripted two-round host. Round 1 emits a checkpoint and tool call; round 2 pauses before its first checkpoint. Trigger handoff and assert the old response cannot detach the new request; publish round 2 checkpoint and assert only that response becomes detachable. Also verify cold-start hydration cannot select round 1 after the round boundary, and persistence failure does not clear the only current owner. A Boolean-only unit test would miss the disk-owner regression.

## Limits

No real OpenAI service, process-kill, or device background behavior was exercised. These are accepted source-level defects with deterministic seams; root owns execution of red tests and integration verification. C3-C7 were outside this second-review packet.
