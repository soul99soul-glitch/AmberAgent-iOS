# Phase 1 — model credential transactions

Status: production implementation complete and frozen for Root's unified green run. No build or test was run by this worker.

## Confirmed red evidence

Root executed the unified regression batch on iPhone 17 Pro Simulator, iOS 26.5. `/tmp/amber-audit-20261018-current/phase1-red-summary.json` records 11 tests with 9 failures and 2 passes overall. Within this worker's four-test suite, all three targeted credential failure cases failed as predicted; the successful removal/reindex control passed. The summary also explicitly records empty first-model headers on restart in the two deletion cases.

## Changes

- `IOSSharedSettingsStore.updateProviderChatModels`, `upsertProviderChatModel`, and `removeProviderChatModel` now reject failed `restoreSnapshot` commits by returning nil and return only the committed provider from `snapshot` on success.
- Removed model/catalog pre-commit Keychain deletion. Existing `restoreSnapshot` owns successful post-commit cleanup of previous versus proposed credential refs. Its existing rollback path therefore retains every old credential if a reindexed surviving model cannot be saved.
- Model editor Save, fetched-model add, model Delete, and Antigravity model seeding now display the existing configuration-save error when the mutation fails, stopping default-selection or success effects.
- The model editor presents the existing alert inside its sheet; the page alert is active only outside the editor, avoiding two presenters for the same error. Failed Save returns false and retains the editor's draft.
- `provider_refresh_models` with `replace_chat` returns its existing structured failure result when the catalog commit fails instead of reporting success.
- Added `IOSModelCredentialTransactionTests.swift`: failed model header update, failed single-model removal, failed catalog replacement, and successful removal with surviving header reindex/restart. It uses the existing credential injection seam plus uniquely provider-scoped Keychain entries so an accidental direct deletion remains observable. It removes only its own Keychain entries and isolated defaults suite.

## Verification and review

- Root red evidence reviewed: actual failures match both candidates, including credential loss on restart.
- One limited `code-simplifier` pass completed against worker-owned diffs compared with `/tmp/amber-audit-20261018-current/credentials-before/`. Simplified cleanup ownership by removing redundant pre-commit deletion; one short view helper owns the four identical failure displays. No retries, fallback storage, new dependency or state machine.
- `git diff --check` for owned files passed.
- Owned Swift files remain below the 1500 physical-line gate: Settings store 1337; provider detail view 1482; config tool service 670; new regression test 211.
- Green tests/build pending Root's unified run. No actual provider, physical-device, or manual model-editor alert acceptance is claimed.

## Unified green selectors

Required narrow regression: `-only-testing:iosAppTests/IOSModelCredentialTransactionTests`

Relevant existing coverage: `-only-testing:iosAppTests/IOSSharedSettingsStoreProvidersWriteBackTests`, `-only-testing:iosAppTests/IOSParityRedLightCredentialTests`, `-only-testing:iosAppTests/IOSProviderConfigToolTests`, and `-only-testing:iosAppTests/IOSSettingsWiringTests`.

## Write ownership / WIP

Repository writes by this worker are confined to three production files (`IOSSharedSettingsStore.swift`, `ProviderDetailView.swift`, `IOSProviderConfigToolService.swift`) and one new test file (`IOSModelCredentialTransactionTests.swift`). Existing WIP in the production files was preserved using task-start copies to separate this patch. No commits, resets, stashes, builds, installs, or device operations were performed.
