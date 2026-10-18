# iOS platform/UI read-only audit

Scope: current working tree at b98bd6f0, including untracked split files. Read iosApp/AGENTS.md; did not edit source, build, or run tests. Covered Council room/run ownership and settings sheets, Home, global Search, settings/provider/SSH input ownership, PhoneControl caller wiring. Watch/Live Activity and DeepRead were delegated narrowly; see audit-platform-system.md for those findings.

## PLAT-1 — P2: Search result navigation ignores selection failure and has no request owner

- Location: iosApp/iosApp/Search/SearchView.swift:227-234; search-result button entry :193-195 and recent button :159-160.
- Trigger and impact: with conversation A current, search result B remains visible but B is deleted elsewhere or its stored conversation fails to load. Tapping B calls selectConversation, discards its success, and unconditionally opens .chat. The user sees A, even though they selected B. IOSConversationStore.swift:536-574 explicitly retains the previous conversation on load failure and exposes selectConversationIfAvailable for UI handling.
- Related ownership: each tap starts a new unretained Task. Tap B then C while storage is suspended: both may commit and navigate in completion order, so an older selection can reclaim current and push an additional chat screen. A task also survives the user dismissing SearchView.
- Second check: not prevented by MainActor; storage.loadConversation suspends. No cancellation handle, commitIf, selected-id guard, path/disappear cancellation, or error presentation exists in SearchView. Home/ConversationsView openConversation already uses all necessary owner checks (cancel previous Task, selectConversationIfAvailable with commitIf, verify current before routing), establishing the existing intended contract without adding a new framework. This is distinct from optional message-hit anchoring, which was not elevated without an explicit contract.
- Minimal repair: keep the selection Task in SearchView state, cancel on superseding selection/dismissal/path change, use selectConversationIfAvailable(commitIf: !Task.isCancelled), route only when the target remains current, and expose the existing unavailable/error state. Preserve query/results on failure. Do not add retries or storage fallback.
- Regression seam: a delayed/injected ConversationStorage load can prove failed B does not navigate/open A; B/C delayed completions and view dismissal cannot commit the stale B selection. Reuse current store test doubles and a small owner/helper seam if needed; do not create a new navigation subsystem.

## PhoneControl caller verification sent to root

Root independently inspects the package dismissKeyboard action. Caller review confirms ToolExecutor.dispatch:155-166 only checks cancellation + controller.canDispatchAction before the primary action, then automatically calls runner.act(.dismissKeyboard) after acknowledged type, with no new foreground or handoff gate. controller.canDispatchAction:601-605 checks owner/phase/handoff but no active app; prepareRunner starts/gets the runner only. Package scope checks are therefore not supplied by this caller; automatic type completion makes dismissKeyboard reachable. Keep the package finding with root rather than duplicate it here.

## Reviewed exclusions / by design

- CouncilChatViewModel guards delayed discussion events, durable awaits, and material completions with discussion/generation ownership. Its page exit leaves the App-owned discussion running; explicit reset/replay checkpoints and stops it. No new page-exit cancellation bug established.
- Council history is explicitly read-only; replay does not overwrite the current transcript. Restart intentionally creates a blank room rather than rerunning the last objective.
- Council settings and mode pickers are disabled during a running discussion. Transient settings-backed participants are replaced by runner roster events. No mid-run settings mutation bug established.
- Home search focus Task and conversation navigation Task are cancelled on superseding work/disappearance, and navigation checks the selected target. No new confirmed Home issue.
- Runtime SSH profile inputs disable editing while authentication verification runs; profile/credential verification rechecks the original persisted profile before committing. The initial suspected draft-overwrite race is not established on the production UI path.
- Provider model fetching keeps provider/header snapshots and request identity. No stale result overwrite established.
- appendDeepReadResultToCurrentConversation ignores save Bool, but has no current production caller; storage agent independently excluded it as a dead path. No deletion proposed.
- Permissions, device availability, and absence of real provider/physical-device evidence are validation boundaries, not standalone bugs.
