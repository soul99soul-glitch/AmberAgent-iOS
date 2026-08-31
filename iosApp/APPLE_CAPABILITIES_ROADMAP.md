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

## Explicitly deferred capabilities

Network Extension/VPN, Apple Pay, Game Center, ClassKit, AutoFill credential provider, Push to Talk, Critical Alerts, Family Controls, Fall Detection, Hotspot, broad Wi-Fi information, NFC, and Wallet are excluded until a concrete product flow justifies their entitlement and review burden.
