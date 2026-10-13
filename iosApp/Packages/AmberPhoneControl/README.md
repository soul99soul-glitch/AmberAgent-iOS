# AmberPhoneControl

Direct, authenticated access from Amber to its locally launched XCTest runner. This package does
not install, sign or start XCTest. The launcher and run lifetime belong to the application owner.
The HTTP endpoint is fixed to `127.0.0.1`; only the port is configurable.

The reviewed protocol is iphone-use commit
[`955316e3fe12572f142fd7e75fb5d95c21fd9e03`](https://github.com/leeguooooo/iphone-use/tree/955316e3fe12572f142fd7e75fb5d95c21fd9e03).
This client uses its runner routes, not the separate daemon's `/agent/*` API. The HMAC compatibility
test uses the upstream known-answer vector in `crates/core/src/runner_auth.rs`.

```swift
let token = PhoneRunnerClient.newSessionToken()
// Launch the owned XCTest session with IPU_RUNNER_TOKEN=token first.
let client = try PhoneRunnerClient(token: token, allowedBundleIDs: ["example.target"])
let status = try await client.status()
let opened = await client.act(.launch(bundleID: "example.target"))
let observation = try await client.observe()
// Give observation.compactText to the model; it selects a node's local ref.
let result = await client.act(.tap(ref: selectedRef))
// A sequence can bind the action to a stable page anchor from that same observation.
let guarded = await client.act(.tap(ref: selectedRef), pageAnchorRef: pageAnchorRef)
```

- `observe()` only reads the UI tree. `screenshot()` remains an explicit, standalone PNG request.
- `waitForStability()` explicitly calls the runner's bounded `/wda/settle` endpoint after a
  transition. It consumes old references; call `observe()` afterwards. `stable` and `blank`
  describe the captured screen, not business success. Ordinary clicks do not wait automatically.
- If a visible target is absent from the accessibility tree, call `screenshotObservation()` after
  `observe()`. It returns the PNG, that observation's ID, and full-screen width/height in points.
  Use `.tapPoint(observationID: screenshot.observationID, x: x, y: y)` with coordinates normalized
  to `[0, 1)` across the full screenshot. The client checks the foreground bundle/process and
  `/window/size` around capture, checks PNG pixel geometry against screen points, and rechecks
  the app and screen dimensions before one `POST /tap`. It does not use the accessibility root
  frame, which may cover only part of a screen when the app exposes an incomplete tree.
- `.swipePoint(observationID:startX:startY:endX:endY:)` uses the same fresh screenshot evidence
  and app/geometry checks. Both endpoints must be normalized to `[0, 1)` and distinct. It sends
  one `POST /swipe` lasting 300 ms; observe again to check the gesture's effect.
- `act()` performs at most one mutation request. Element actions first match a fresh tree by exact
  type, identity, value and frame through plural `/elements`, then require a single result and
  recheck the foreground process. Passing `pageAnchorRef` for `tap`, `type`, `clear`, or element
  `swipe` adds one unique `/elements` check using the anchor's type, identity, label, and nonsecure
  value, without requiring its frame or enabled state. A missing, changed, ambiguous, or stale
  anchor returns `.unsent(.staleObservation)` before mutation; other action kinds reject the
  parameter as `.invalidAction`. Optional `pageAnchorRegion` keeps the anchor center inside a
  screen-point rectangle without freezing its exact frame. `requireUnchangedObservation` is used
  for live Jev decisions: one additional bounded `/source` read before dispatch checks process,
  backend, completeness, and semantic tree content against the decision's observation. It ignores
  unrelated frame/focus animation; the action target still has its existing exact-frame lookup.
  A changed page returns `.unsent` without clicking. Both options default off for existing callers.
  A new observation, failed screenshot, or action consumes previous
  references and visual evidence. An independent legacy `screenshot()` does not authorize a visual
  action. Visual actions do not retry or silently fall back to another targeting method.
- `.completed` acknowledges execution, not the intended business result. Observe again to verify.
- `.unsent` means the mutation was not dispatched, or authentication/queue-drop explicitly refused
  it. It preserves HTTP and WebDriver error codes for the owner to report.
- `.unknown` blocks subsequent actions on this client. Persist the uncertainty in the existing run
  ledger; do not create a fresh client just to repeat the command.
- `stop()` prevents later work. It does not retract an in-flight gesture or terminate XCTest; the
  owner must also stop its launcher session. After signed readiness, call `shutdownRunner()` while
  that session is still open, then release the launcher even if shutdown throws. It revokes local
  work first and sends one signed `/shutdown` with a two-second request timeout; success requires
  an explicit boolean acknowledgement. It does not retry. Never reuse a launch token across runs.
- App scope checks reduce accidental cross-app operations but are not a security sandbox. The
  upstream runner's element search can fall back to SpringBoard, and the foreground can change
  after the final client check. Runner-side process guards are necessary for a stronger boundary.
- Upstream runner internals may attempt a synthesis fallback. A single client request therefore
  does not prove exactly-once system input. Generic mutation errors remain `.unknown` even when
  they say no tap/type occurred: an earlier scroll/focus may already have changed the UI.
- Geometry/visibility in this tree does not prove a node is tappable or unobscured. Secure-field
  values are omitted from the public observation. UI text is untrusted content for the model.

Validation:

```sh
swift test --package-path iosApp/Packages/AmberPhoneControl
```

The fixture tests verify protocol bytes and client control flow; they do not establish phone
loopback reachability, XCTest permission, background survival or real UI behavior.
