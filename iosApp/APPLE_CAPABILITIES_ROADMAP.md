# Apple Developer Program capability roadmap

This roadmap turns the paid Apple Developer Program membership into product value in small, reviewable slices. A capability is enabled only when a user-facing flow consumes it and the release build can prove the required entitlement, privacy declaration, and failure behavior.

## Cross-phase delivery gate

Every phase must pass all of the following before the next phase starts:

1. The feature has one clear owner and a complete UI → service → platform API → persistence/result path.
2. Entitlements, `Info.plist`, App ID requirements, and the in-app capability diagnostic agree.
3. Unit or integration tests cover success, denial/unavailable, cancellation, and stale-state behavior that exists in that phase.
4. Simulator build and targeted tests pass. System permissions, signing, background behavior, and HealthKit receive separate device evidence when a configured device is available.
5. A code-review subagent and a UI-review subagent independently inspect the completed phase. Findings are fixed and reverified before the phase is closed.
6. External Apple-account work is listed explicitly and never reported as complete without evidence from that account.

## Phase 0 — release foundation

Status: completed locally. Release arm64 simulator build and code/UI review passed; paid signing identity and TestFlight remain external evidence.

Goal: produce a release-safe project that can be signed by the paid Individual team and installed through internal TestFlight as soon as the local signing identity is present.

- Keep `project.yml` as the source of truth; never hand-edit generated Xcode project settings.
- Separate stable and experimental entitlements so experimental capabilities cannot leak into the App Store target.
- Add release preflight checks for entitlement mirrors, privacy declarations, background modes, bundle identifiers, and unresolved placeholders.
- Remove release-only permission declarations that have no current feature consumer.
- Disable the near-silent audio keep-alive by default and exclude the `audio` background mode from the App Store target. Continue using bounded UIKit cleanup plus `BGContinuedProcessingTask`/durable recovery.
- Add a privacy manifest owned by the app target and an App Store/TestFlight release checklist.
- Verify the iOS app, Activity widget, and Watch companion build together.

Exit evidence:

- XcodeGen generation succeeds.
- Release simulator build and targeted background/entitlement tests pass.
- A release archive either validates with a paid identity or fails with an explicit signing prerequisite.
- Internal TestFlight installation is external evidence and remains unchecked until observed.

## Phase 1 — HealthKit read-only local MVP

Status: completed locally. Stable/experimental gating, 15 targeted tests, arm64 build, and code/UI review passed; physical-device Health authorization remains external evidence.

Goal: provide a useful, reviewable activity summary without handing HealthKit data to a model or remote store.

- Enable the base HealthKit entitlement only on the stable iOS target.
- Replace generic usage text with a specific localized purpose.
- Request only step-count read access in the first slice. Do not request HealthKit write, clinical records, background delivery, or Watch HealthKit access.
- Add a dedicated Health summary service and UI with today/7-day aggregates, loading, empty, unavailable, and authorization guidance states.
- Keep HealthKit values ephemeral: no conversation transcript, agent memory, logs, analytics, backup, WebDAV, CloudKit, or model-provider transmission.
- Preserve the existing high-risk capability gate; the agent-facing `health_step_count_summary` tool remains blocked until a later separately reviewed product decision.

Exit evidence:

- Entitlement diagnostics pass and the permissions screen no longer reports a missing HealthKit entitlement.
- Deterministic service tests pass.
- Simulator shows the unavailable/sample-safe UI without crashing.
- Physical-device authorization/query evidence is recorded when a signed device build is available.

## Phase 2 — native assistant surfaces

Status: completed locally. App Intents, local notifications, WeatherKit, deep-link routing, 14 targeted tests, simulator build, and independent code/UI review passed; real WeatherKit data and notification behavior remain physical-device evidence.

Goal: make existing Amber actions reachable through Apple system surfaces without introducing a backend dependency.

- Add App Intents/App Shortcuts for opening a new conversation, resuming the latest conversation, and opening the active task.
- Implement local completion/reminder notifications using the existing permission coordinator. No remote push claim is made.
- Add WeatherKit as a bounded read-only tool and UI card; current-location weather reuses the existing location permission, while named locations work without it.
- Centralize deep-link parsing and add Associated Domains only when a real HTTPS domain/AASA pair is configured. The custom `amber://` route remains the deterministic fallback.
- Do not enable Critical Alerts, Communication Notifications, or Time Sensitive Notifications in this phase.

Exit evidence:

- Intent parameter validation and deep-link routing tests pass.
- Notification scheduling/cancellation tests pass.
- Weather loading/error/permission UI states are visually inspected.
- Any domain-dependent path reports “not configured” instead of pretending to work.

## Phase 3 — encrypted cross-device and deployable backend boundary

Status: completed locally. CloudKit private sync, optional Apple sign-in, backend-gated APNs/App Attest, 21 targeted tests, simulator build, and independent code/UI review passed; two-device CloudKit and production APNs remain external evidence.

Goal: add safe Apple-backed sync now and leave a complete, testable contract for services that truly require a backend.

- Implement CloudKit private-database storage as another encrypted snapshot provider, reusing the existing preview/conflict/manual-restore contract.
- Sync neither credentials nor HealthKit-derived data. Preserve local/WebDAV providers.
- Add Sign in with Apple only as an optional account-boundary module; local-first use stays available without an Amber account.
- Add APNs registration/token lifecycle and an App Attest client only behind an injected backend configuration. Without a configured HTTPS backend, both remain honestly unavailable and do not register or upload identifiers.
- Remote task-completion pushes require durable server-owned execution and are not represented as working from local-only model runs.

Exit evidence:

- CloudKit provider contract tests cover list/upload/download/delete/conflict and offline retry.
- Snapshot privacy tests prove credentials and HealthKit data are excluded.
- Auth/push/attestation state machines pass with local fakes and fail closed when backend configuration is absent.
- Two-device CloudKit and production APNs remain external evidence until available.

## Phase 4 — StoreKit 2 commerce

Status: completed locally. The app-level StoreKit listener, finish-after-persist transaction flow, iCloud encrypted-backup Pro gate, 15 targeted tests, simulator build, and independent code/UI review passed. App Store Connect products, a public privacy-policy URL, and Sandbox/TestFlight purchase remain external evidence; new purchases stay disabled until the policy URL is configured.

Goal: support a coherent subscription purchase lifecycle without using Apple Pay for digital functionality.

- Add StoreKit 2 products, purchase, restore, entitlement refresh, revocation, expiration, grace period, and billing-retry states.
- Keep the product catalog injectable and include a local StoreKit configuration for deterministic tests.
- Gate only declared premium features; local data access and purchase restoration are never blocked by account sign-in.
- Amber Pro currently unlocks encrypted cross-device snapshots in the user's private CloudKit database; local backups, local-folder sync, and WebDAV remain available without a subscription.
- Verify signed transactions locally. Server verification remains optional until the Phase 3 backend is configured.
- Add a compact subscription screen using existing Amber form components and semantic spacing.

Exit evidence:

- Local StoreKit tests cover purchase, cancel, pending, restore, revoke, expire, and offline cached entitlement.
- Subscription UI is inspected at standard and large Dynamic Type sizes.
- Sandbox/TestFlight purchase is external evidence and remains unchecked until observed.

## Phase 5 — EventKit task-management closure

Status: completed on 2026-09-01.

Goal: turn the existing calendar and reminders tools into a complete, identifier-based task-management loop without introducing a second local database.

- Add calendar event update and delete tools alongside the existing list/create tools.
- Add reminder update and delete tools alongside the existing list/create/complete tools.
- Preserve EventKit identifiers in every result so a read can feed the next mutation without title matching.
- Support bounded recurrence for event creation/update and explicit list/calendar selection only when EventKit exposes a stable identifier.
- Prefer write-only calendar access for create-only requests; require full access only for reads or mutations of existing events.
- Keep every mutation foreground-approved and return the committed EventKit snapshot rather than echoing requested input.

Exit evidence:

- Read → update/delete and create → read-back paths are deterministic in executor tests.
- Permission denial, missing identifier, invalid recurrence, and stale/deleted item errors are explicit.
- The approval card fits long titles, dates, and Dynamic Type without clipping or ambiguous destructive actions.
- `AppleToolDeclarationTest` and `AppleToolSearchAliasTest` pass on JVM; iOS capability/runtime/Health/notification tests pass on iPhone 17 Pro Simulator.
- Logic and UI sub-agent reviews completed with no remaining Phase 5 blocking findings.

## Phase 6 — actionable App Intents

Status: completed locally on 2026-09-01. Three actionable intents, durable-store App Entities, opaque foreground handoff, six-language system resources, 5 targeted deep-link tests, and independent logic/UI review passed; Siri/Spotlight behavior remains signed-device evidence.

Goal: expose useful Amber actions to Siri, Spotlight, Shortcuts, widgets, and hardware triggers instead of only opening app destinations.

- Add parameterized intents for asking Amber, generating a bounded daily brief, and running one saved prompt/task.
- Represent conversations and saved actions as App Entities backed by existing durable stores; do not create a parallel intent-only store.
- Foreground-handoff any action that needs provider credentials, sensitive tools, or approval. Background execution is limited to deterministic local reads.
- Return a concise system result and a deep link to the owning conversation/task.
- Keep the existing navigation intents as fast, non-destructive shortcuts.

Exit evidence:

- Intent parameters, entity lookup, missing/deleted entities, deep links, and foreground handoff are covered by focused tests.
- App Shortcut phrases are localized and do not duplicate or crowd the Shortcuts catalog.
- Siri/Spotlight/Shortcut surfaces use short titles and compact result text at accessibility sizes.

Exit evidence:

- Ask Amber, Daily Brief, and Saved Action reuse the existing conversation/settings stores and publish only three promoted App Shortcuts.
- Provider work uses an in-memory, opaque, single-use handoff; direct URLs cannot inject a prompt, and concurrent deep-link openers are serialized.
- App Intents, App Shortcuts, and Siri purpose strings are localized for English, Simplified/Traditional Chinese, Japanese, Korean, and Russian.
- `IOSAppDeepLinkTests` passed on iPhone 17 Pro Simulator; independent logic and UI reviews found no remaining Phase 6 blocking issue.

## Phase 7 — AlarmKit time-critical actions

Status: completed locally on 2026-09-01. AlarmKit scheduling/list/cancel, Amber-owned reconciliation, stop/open App Intents, six-language alarm resources, targeted simulator tests, and independent logic/UI review passed. A signed-device fire/stop check remains part of the final installation gate.

Goal: add prominent alarms and timers for requests that should not be modeled as ordinary local notifications.

- Add schedule, list, and cancel tools using AlarmKit; support one-time alarms, weekly recurrence, and countdown timers.
- Persist only Amber-owned alarm metadata and reconcile it against `AlarmManager` on launch.
- Reuse App Intents for stop/secondary actions and the existing Activity widget target for countdown presentation.
- Keep local notifications for ordinary reminders and task completion; never silently upgrade them to alarms.
- Add the required usage description and capability diagnostics only when the stable target consumes the framework.

Exit evidence:

- Authorization, schedule validation, recurrence, reconciliation, cancellation, and already-fired behavior are tested.
- Alarm approval clearly distinguishes an intrusive alarm from an ordinary notification.
- Signed-device evidence verifies one alarm fires and can be stopped; simulator evidence remains explicitly limited.

Exit evidence:

- One-time, weekly, and timer validation is fail-closed; authorization is rechecked against current time immediately before the system commit, and metadata is written only after AlarmKit succeeds.
- Amber-owned identifiers drive list reconciliation and cancellation; fired or externally removed alarms are pruned without title matching.
- Alarm alert/countdown titles use the user title, while stop/open controls and Activity widget copy ship through one six-language resource variant group in both app and widget products.
- `IOSAlarmKitTests` and `IOSCapabilityRegistryTests` pass on iPhone 17 Pro Simulator; final logic/UI reviews found no remaining Phase 7 code or layout issue.
- Physical alarm delivery and stop behavior remain explicitly pending until the final paid-signing device install.

## Phase 8 — picker-first personal context

Status: completed locally on 2026-09-01. Contact, photo, and Journaling Suggestions pickers now use explicit foreground selection and confirmation; provider image handoff, bounded temporary storage, targeted tests, and independent logic/UI review passed. The Journaling Suggestions entitlement still requires final paid-signing device evidence.

Goal: let the user deliberately hand selected contacts, photos, and journaling suggestions to Amber without broad background enumeration.

- Add foreground picker tools for contacts and photos; return only the selected items needed by the active request.
- Add a Journaling Suggestions picker when the paid App ID and signed target contain the required entitlement.
- Copy selected media into bounded app-owned temporary/workspace storage before model use; revoke picker handles after the run.
- Do not implement full-library `media_search`, full-address-book search, or silent journaling access.
- Show a compact preview and explicit handoff action before selected personal context enters a provider request.

Exit evidence:

- Contacts are returned only from `CNContactPickerViewController`; photos only from `PhotosPicker`; Journaling Suggestions only from Apple's foreground picker. Every path ends in a compact confirmation sheet or an explicit cancel/error result.
- Selected media is downscaled off the main actor, capped at 20 MB per item and 40 MB per request, converted to provider-safe image parts, and removed after handoff, cancellation, failure, or expiry.
- Cancel, empty selection, unavailable entitlement, stale temporary file, and successful handoff paths are covered; picker sheets were reviewed for safe areas, selection counts, long names, aspect ratios, Dynamic Type, and VoiceOver.
- Unselected contacts, photos, and suggestions never enter logs, sync, memory, or transcripts.
- OpenAI Chat/Responses, Claude, and Gemini all preserve picker image tool outputs; `IOSPersonalContextPickerTests`, `IOSGeminiProviderTests`, provider/KMP declaration tests, and capability tests pass.
- Final independent logic and UI reviews found no remaining Phase 8 P0–P2 issue; signed-device Journaling entitlement and picker behavior remain part of the final installation gate.

## Phase 9 — WorkoutKit planning loop

Status: completed locally on 2026-09-01. Preview, approved schedule/list/remove, stable Amber ownership metadata, unsupported-device handling, targeted tests, generic iPhone build, and independent logic/UI review passed. A paired-Watch schedule remains part of the final physical-device gate.

Goal: turn HealthKit observations into user-approved workout plans that can be previewed and scheduled in the Apple Watch Workout app.

- Add preview, schedule, list, and remove tools for a deliberately small workout vocabulary: time/distance goals, pacer workouts, and bounded work/recovery intervals.
- Require an explicit user request and foreground approval before scheduling or removing a workout.
- Keep HealthKit analysis read-only; WorkoutKit owns scheduled plans and no workout samples are written to HealthKit.
- Return WorkoutKit's committed schedule and stable Amber metadata so later changes are identifier-based.

Exit evidence:

- Unsupported devices, authorization denial, invalid interval structure, capacity limits, scheduling, and removal are tested.
- The preview makes units, date, duration, and repetition legible without presenting medical advice.
- `workout_plan_preview` is background-safe; schedule/list/remove remain foreground approval-gated, and unsupported or temporarily unavailable schedulers never erase Amber ownership metadata.
- Kotlin declarations, registry/search exposure, Swift approval/dispatch, WorkoutKit commit confirmation, reconciliation, and stable-ID removal are covered end to end; HealthKit remains read-only.
- Targeted Kotlin tests, `IOSWorkoutKitTests`, capability/permission tests, and a generic iPhone build pass; final independent logic and UI reviews found no remaining Phase 9 P0–P2 issue.
- A paired-Watch schedule remains external evidence until observed on the physical devices.

## Phase 10 — interactive Live Activity and Watch control

Status: completed locally on 2026-09-01. Live Activity and watchOS controls now share durable run ownership, exact command identity, cold-launch recovery, stale-snapshot rejection, and bounded retry eligibility. Targeted simulator tests, generic iOS/watchOS builds, independent logic/UI review, and a paid-Team signed Release build passed; the final control round-trip remains physical-device evidence.

Goal: make long-running Amber work controllable from glanceable Apple surfaces while preserving run ownership and approval boundaries.

- Add App Intent-backed cancel, open, and retry actions to Live Activity where the current durable run state allows them.
- Add the same bounded controls to the watchOS companion, with WatchConnectivity commands carrying `runId` and an idempotency key.
- Keep sensitive approvals in the iPhone app unless the approval payload is already safely represented by the existing Watch approval contract.
- Reconcile stale Live Activities and Watch snapshots on app launch; an old surface must never cancel or relaunch a newer run.
- Do not claim remote continuation when the provider lacks server-owned execution and cursor recovery.

Exit evidence:

- Success, stale run, duplicate command, offline Watch, cancellation race, and retry ownership paths are tested.
- Lock Screen, Dynamic Island, StandBy, accessibility sizes, and 40/42/46 mm Watch layouts receive visual review.
- A physical-device run verifies at least one control round-trip without losing conversation data.
- Live Activity cancel/retry/open controls execute in the app process, wait for the state-backed owner on cold launch, and never report success unless the matching foreground/background owner accepts the operation.
- Retry is fail-closed across restarts through a bounded durable eligibility record plus latest-run, conversation-revision, transcript, and orchestrated-child revalidation.
- Watch protocol v2 rejects offline queuing, duplicate/stale decision IDs, old run generations, and late approval answers; a persisted completed run may still open after cold launch only after durable run-to-conversation validation.
- Persisted BG continued-processing identifiers register before `applicationDidFinishLaunching` returns and hydrate a headless runtime when SwiftUI has not created `AppShell`.
- Phase 10 targeted tests, generic iOS/watchOS builds, strict nested-code signature verification, and independent logic/UI reviews pass. The signed artifact uses `app.amber.ios` and paid Team `TY4JTL3V2M`; physical installation/control evidence remains pending while the registered iPhone is unavailable to CoreDevice.

## Explicitly deferred capabilities

Network Extension/VPN, Apple Pay, Game Center, ClassKit, AutoFill credential provider, Push to Talk, Critical Alerts, Family Controls, Fall Detection, Hotspot, broad Wi-Fi information, NFC, Wallet, full-library media search, full-address-book enumeration, and always-on location are excluded until a concrete product flow justifies their entitlement and review burden.
