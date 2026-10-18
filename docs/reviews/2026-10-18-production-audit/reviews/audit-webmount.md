# WebMount production audit — 2026-10-18

Scope: current working tree, including the in-progress Swift module split. Read-only source/test audit; no source or test edits, no builds or test execution. Reviewed local controller/commands, session store, WK bridge/runtime, URL/redaction, station/cookie/artifact stores, desktop mapping/semantics/backend, browser presentation and content handoff. Exact lines below refer to the current tree at review time. No other product repository was accessed. Memory search produced no task-specific evidence.

## Confirmed issues

### WM-1 [P1] Restart silently discards every persistent local session except the first

**Primary location:** `iosApp/iosApp/WebMount/IOSWebMountSessionStore.swift:251-258`.

**Reachable chain:** foreground-approved `wm_tab_new` with `persistent:true`, default `backend:local` → controller `tabNewResult` at `IOSWebMountController.swift:1022-1036` → `SessionStore.newSession` at `IOSWebMountSessionStore.swift:411-437` creates an independent local runtime and saves `persistentOptIn=true`. This can be done twice within the default 3-runtime limit (initial ephemeral plus two persistent). `persistSessions` at 820 onward writes *all* opted-in metadata. After restart, init selects `persisted.first(where: backend == .local)` and then fills remaining slots exclusively from `backend != .local`; the second and third persisted local sessions never enter either runtimes or metadata. The next ordinary touch persists this reduced metadata, permanently removing the previously saved entries.

**Observable impact:** opted-in station/session metadata, retained conversation association, saved title/URL and reopen card disappear after restart; which local survives is ID-sort order rather than the user's persisted current session.

**Second review / by-design check:** the comment at 249-250 requires reserving *one slot* so remote sessions cannot crowd out the only local WKWebView; it does not specify a maximum of one local. `newSession` has no such restriction, uses one independent local runtime per call, and supports switching among local sessions. `ensureCurrentSessionIsLocal` only ensures the current session is local, rather than pruning others. Existing `testWebMountSessionTTLAndPersistentMetadataRestoreFreshRuntimeOnly` in `IOSWebMountSessionToolTests.swift:441` saves only one persistent local and therefore misses this. A deliberate singleton policy would also need to prevent the accepted creation/persistence path; current behavior is data loss.

**Minimum fix:** preserve a local reservation, then fill remaining capacity from all not-yet-selected persisted sessions in deterministic order, rather than filtering to remote only. Keep the existing rule that no persisted page state/action is automatically resumed. Do not add a persistence format or runtime abstraction.

**Test seam:** isolated UserDefaults + MockWebMountRuntime factories already exist. Persist two or three local sessions and a selected local ID, reconstruct the store, assert every in-limit opted-in ID is retained, current ID survives, runtimes start idle/needsReopen, and no navigation occurred. Retain the existing remote-only persistence local-reservation case.

### WM-2 [P2] The browser refresh control opens the redacted display URL, losing query/fragment or navigating to /redacted

**Primary location:** `iosApp/iosApp/WebMount/Presentation/WebMountSiteView.swift:478-483`; dependent navigation at `:1239-1242`.

**Reachable chain:** user opens `https://example.com/search?q=PS5#results` (or follows that URL in the page) → `IOSWebMountWKRuntime.finishNavigation` at `IOSWebMountWKRuntime.swift:963-975` stores `snapshot.currentURL` using `IOSWebMountRedactor.redactedURL` → redactor at `IOSWebMountRedactor.swift:111-123` intentionally omits query and fragment and replaces sensitive-looking paths with `/redacted` → address state copies this value at `WebMountSiteView.swift:325-327` and `:1248` → unfocused refresh button labelled “重新加载当前页面” calls `openTypedURL()` → `openForUser(url:openURLText)` navigates to `https://example.com/search`, or `/redacted` for a path such as `/oauth/callback`.

**Observable impact:** clicking refresh loses the active search/filter/SPA route, and sensitive callback pages can become a different or 404 page. This is reproducible from the deterministic data flow even with a normal non-sensitive query URL.

**Second review / by-design check:** stripping secrets from snapshots and address display is intentional and should remain. Using that display-only value as a reload destination is separate from redaction and contradicts the control's explicitly labelled behavior. Typed-address submit should continue to use the address text; only the unfocused refresh action should reload the actual current page.

**Minimum fix:** separate refresh from typed-address navigation. The current WKWebView already owns the full current URL / request; use its real reload path (with current user ownership and navigation policy) rather than reconstructing a destination from the redacted snapshot. Avoid exposing a raw URL to tool outputs or persistent metadata and avoid a second mirrored URL state.

**Test seam:** existing WK runtime/browser fixtures can `history.replaceState` to `/fixture?q=PS5#results` without relying on a provider. Add a narrow controller/runtime reload seam or UI regression that proves the dispatched full destination remains unchanged while snapshot/tool URLs remain redacted. Also cover address-bar editing still opening the explicitly typed URL. The existing source-only SwiftUI layout tests cannot validate reload behavior alone.

### WM-3 [P2] Desktop wm_type trims the actual user payload and cannot clear a field

**Primary location:** `iosApp/iosApp/WebMount/Desktop/IOSWebMountDesktopMapping.swift:230-242`; shared identifier helper at `:383-384`.

**Reachable chain:** enabled anonymous station + connected desktop backend → current semantic textbox and snapshot pass existing ownership/preflight checks → `wm_type` with `text:"  hello\n"` → mappedArguments calls `string(arguments,"text")` → helper trims `.whitespacesAndNewlines` and returns `"hello"` → browser_type receives different text. With `text:""` or whitespace-only text (including a single space), `.nilIfBlank` makes it nil, so the same request is rejected with `wm_type requires text` instead of replacing/clearing the field. The `value` alias follows the same path.

**Observable impact:** draft formatting and literal values are changed silently on desktop, and the normal replace-with-empty operation cannot clear an existing input. This differs from local WebMount behavior and makes the same tool's meaning depend on its backend.

**Second review / by-design check:** identifier trimming is sensible for target IDs, condition names and URLs, but text content is not an identifier. Public schema `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt:4381-4403` declares arbitrary string `text`/`value`, without nonempty or trim semantics. Local controller takes `args["text"] as? String ?? args["value"] as? String`, and bridge `IOSWebMountBridgeScripts.swift:889-899` writes the exact text and verifies equality, including an empty string. Therefore this is an implementation mismatch rather than a sanctioned backend limitation.

**Minimum fix:** read literal strings directly for `wm_type` text/value (nil means absent; empty is valid); keep existing trimmed helper for control/identifier fields. Consider the same literal issue for desktop `wm_keys` space and select option values only if adding focused coverage; no need to redesign the entire mapping layer.

**Test seam:** `IOSWebMountDesktopBackendTests` / DesktopMcpClientFake already captures remote arguments. On a safe structured textbox, verify `"  hello\n"`, `""`, and the `value` alias reach `browser_type` exactly; no submit flag or approval semantics should change. A pure `mappedArguments` test is sufficient for the literal conversion, paired with the existing backend dispatch path.

## Excluded / not promoted

- Multiple raw `key`/`option` aliases in `wm_act`: the published canonical keys/select API uses `text` or `value`; local handling of undeclared aliases alone is not evidence of a defect.
- Agent lease expiry retains ownerRunId: explicitly asserted by `IOSWebMountSessionToolTests` and paired with releaseAgentOwnership; do not clear it speculatively.
- Local back/forward return a loading snapshot rather than awaiting completion: the current runtime is deliberately asynchronous; no confirmed user contract violation from this alone.
- URL redaction itself, exact host allowlists, user-only screenshot/vision, high-consequence approvals, semantic-ref requirements and unsupported remote mappings: intentional boundaries; no theoretical guard additions proposed.
- Potential `wm_keys` optimistic verification for page input handlers that restore a value was noticed but was not executed or fully reviewed; do not count it as a confirmed finding in this batch.

## Suggested bounded repair phases

1. Session persistence selection + isolated restore regression; independent subagent review of the changed selection and reservation rules.
2. Refresh/navigation ownership seam + WK query/fragment regression while retaining redacted snapshots; independent subagent review.
3. Literal desktop input mapping + focused argument regressions; independent subagent review, then only the affected WebMount suites.

Validation boundary: all three findings above are confirmed by current reachable source paths and the counterevidence checks described; no failing test has yet been obtained in this read-only audit. The parent should first make each failure observable before applying its repair. No claimed simulator or real-device acceptance.
