# Phase 5 WebMount implementation handoff

Status: WM1–WM3 production fixes and targeted tests are implemented and frozen. This worker did not build or run tests. Root owns serial integration builds and test execution. No commits, pushes, resets, stashes, or changes to another owner's files.

## Changes owned by this worker

- `iosApp/iosApp/WebMount/IOSWebMountSessionStore.swift`: reserve a local slot, then fill remaining restore capacity from every remaining opted-in session, including additional local sessions. Existing max capacity, explicit reopening, fresh runtime and remote-only reservation behavior remain.
- `iosApp/iosApp/WebMount/Desktop/IOSWebMountDesktopMapping.swift`: only wm_type's business text/value is read literally. Empty text, whitespace and newlines remain valid. Identifier/target normalization and keys/select mappings are unchanged.
- `iosApp/iosApp/WebMount/IOSWebMountWKRuntime.swift`: native reload uses WebKit's actual current request. There is no raw URL mirror, new runtime protocol requirement, retry, timeout model or fallback. A missing page produces an actionable failed result; current navigation policy remains owned by the existing WK delegate.
- `iosApp/iosApp/WebMount/IOSWebMountController.swift`: reloadForUser checks the existing local session, current user control and reopen state. It never acquires control and returns an explicit failed snapshot on rejection. Accepted reload touches the existing session.
- `iosApp/iosApp/WebMount/Presentation/WebMountSiteView.swift`: address editing retains the typed navigation path; unfocused refresh calls reloadForUser and displays returned failure. No URL state was added.

New test files owned here:

- `IOSWebMountPersistentSessionRestoreTests.swift`
- `IOSWebMountLiteralDesktopInputTests.swift`
- `IOSWebMountReloadDestinationTests.swift`

Task-before production snapshots are in `/tmp/amber-audit-20261018-current/webmount-before/`. The diff against those snapshots contains only the five changes listed above, preserving the preexisting Swift module split WIP.

## Root-observed pre-fix failures

Verified by reading the current Root result summaries:

- `future-domain-red-summary.json`: persistence restores only `[persistent-local-1]` instead of both opted-in local IDs.
- The same summary: four literal desktop input tests fail. Empty/single-space text is rejected with `wm_type requires text`; leading/trailing whitespace/newlines are stripped from the other two payloads.
- `pending-domains-red-summary.json`: the real WK fixture through the existing refresh button pipeline requests `https://fixture.example/search` rather than `https://fixture.example/search?q=PS5#results`.

The WM2 regression now calls the formal reloadForUser entry point while preserving its URL/ownership/redaction assertions and requiring WK navigation type reload. Additional tests require an agent-owned page to reject refresh without dispatch or ownership change, and an unopened user-owned page to return an actionable error. The previous direct native-WK boundary control remains.

## Focused green selectors

```
iosAppTests/IOSWebMountPersistentSessionRestoreTests
iosAppTests/IOSWebMountLiteralDesktopInputTests
iosAppTests/IOSWebMountReloadDestinationTests
```

Relevant existing regression suites after the focused checks:

```
iosAppTests/IOSWebMountSessionToolTests
iosAppTests/IOSWebMountRemoteSessionTests
iosAppTests/IOSWebMountDesktopBackendTests
iosAppTests/IOSWebMountWKRuntimeTests
iosAppTests/IOSWebMountRuntimeEvidenceTests
```

## Finite maintainability review and evidence boundary

Applied code-simplifier once to this task's diff against the saved before snapshots, with the Swift/SwiftUI guidance. The entry points are controller reloadForUser and the UI refresh/editing branch; page URL remains owned by WKWebView. No unrelated formatting, dead-code deletion, new raw URL state, default fallback, protocol expansion or keys/select scope was introduced. All five before/current diff --check operations and all three new-file whitespace checks emitted no errors (no-index exit 1 means the files differ).

The independent read-only WebMount implementation review is assigned to audit_kmp and will be recorded in `phase5-webmount-independent-review.md`. Root will incorporate that report into the overall Phase 5 review; no additional review delegation will be initiated by this worker.

Pending evidence: post-fix compile and test results from Root; real device address-bar/keyboard interactions and real desktop MCP input behavior are not accepted by these fixture tests.
