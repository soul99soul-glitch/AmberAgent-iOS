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
```

- `observe()` only reads the UI tree. `screenshot()` is an explicit, separate PNG request.
- `act()` performs at most one mutation request. Element actions first match a fresh tree by exact
  type, identity, value and frame through plural `/elements`, then require a single result and
  recheck the foreground process. A new observation or action consumes previous references.
- `.completed` acknowledges execution, not the intended business result. Observe again to verify.
- `.unsent` means the mutation was not dispatched, or authentication/queue-drop explicitly refused
  it. It preserves HTTP and WebDriver error codes for the owner to report.
- `.unknown` blocks subsequent actions on this client. Persist the uncertainty in the existing run
  ledger; do not create a fresh client just to repeat the command.
- `stop()` prevents later work. It does not retract an in-flight gesture or terminate XCTest; the
  owner must also stop its launcher session. Never reuse the same launch token across runs.
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
