# Amber iPhone control launcher

Standalone Rust static library for the app-owned development session. Public C
ABI is `include/AmberIPhoneControl.h`; Swift imports `AmberIPhoneControl` using
the adjacent module map. The app supplies already prepared RemotePairing bytes,
an endpoint, installed runner bundle ID, built test module, and a new hex token.

```
./build.sh
cargo test --locked -p amber-iphone-control
```

Libraries are `target/aarch64-apple-ios/release/libamber_iphone_control.a` and
`target/aarch64-apple-ios-sim/release/libamber_iphone_control.a`. `Cargo.lock`
pins transitive dependencies. `build.sh` sets `IPHONEOS_DEPLOYMENT_TARGET=26.0`
so ring's C/assembly objects do not silently inherit a newer beta SDK minimum.
This is a separate workspace; it does not alter
Amber's existing native workspace or KMP build.

## Session and protocol ownership

`start` copies inputs and returns immediately. Each handle owns one OS thread
and Tokio current-thread runtime. That runtime contains the RemotePairing
control socket, CDTunnel TLS-PSK connection, software TCP adapter, service
directory and three DTX sessions. Stopping cancels the entire runtime; no
detached network task survives `free`. The Swift owner must call `free` off
the UI thread and serialize destruction against status/stop calls. No callback
ever retains a Swift pointer.

Status has finite phases and stable error codes. Native diagnostics expose
`IdeviceError.code()` and `sub_code()`, plus typed I/O kind and OS error code
when available. Pair-verify failures retain the same redacted fields.
Untrusted protocol error text is not surfaced. The session disables upstream tracing on its own runtime thread
because upstream pairing parsing logs private plist contents at debug level.

The control-start entry verifies existing RemotePairing material only. It
deliberately does not call the upstream `connect` convenience method that falls
back to creating a new pairing. A rejected pairing is an actionable failure.

Explicit first preparation uses the separate `pairing_start` entry point. It
implements upstream's documented iOS network pair-setup (`pair_rsd_ios.rs`
`wifi_pair_flow`): new local identity → RemotePairing handshake → system
consent → SRP verification → save peer record. It never launches an app. The
phase is `waiting_for_consent` while requesting approval, then `paired` only
after the full protocol succeeds. Rejection/cancellation/90-second timeout
returns without exporting any private result. The control-start API never
implicitly invokes this setup operation.

Only `pairing_copy_plist` can copy a successfully prepared private XML result;
it is absent from status. The caller may save the returned bytes to local
Keychain after the explicit preparation action, then must free the copy. Rust
does not write it to disk. USB is not a prerequisite in upstream's network
pairing implementation, but accepting same-device loopback pairing remains a
device acceptance gate. The iOS consent branch uses its protocol setup code
only after receiving the device's `awaitingUserConsent` response and subsequent
pairing data; it does not bypass an unanswered or rejected system prompt.

The connection path is:

```
TCP RemotePairing endpoint
  -> attemptPairVerify + validatePairing
  -> create_tcp_listener + TLS-PSK CDTunnel
  -> RSD handshake
  -> trusted lockdown over RSD (ProductVersion)
  -> installation_proxy over RSD (runner metadata)
  -> testmanagerd control + testmanagerd main + dtservicehub
  -> upstream XCTest configuration, launch, authorization and event loop
```

No lockdown pairing record, USB bridge, CoreDeviceProxy tunnel or unsigned
WDA readiness request is needed by this entry point. This is an implementation
path, **not proof that a particular iOS version allows self-control**.

The control-start ABI defaults to `10.7.0.1:49152`, matching the originally researched loopback
route. Callers can pass an observed local endpoint such as `127.0.0.1:49152`.
The first-preparation API defaults to `127.0.0.1:49152`. The library never
installs or changes VPN/network settings. Neither endpoint's TCP availability
proves pairing or automation authorization.

The installed runner executable and supplied module must agree. For the pinned
iphone-use runner: bundle `app.amber.selfcontrol.runner.xctrunner`, executable
`iPhoneUse-Runner`, module `iPhoneUse`, plugin `iPhoneUse.xctest`, filter
`iPhoneUse.RunnerTests/testServe`. Launch injects `IPU_RUNNER_TOKEN` and disables
continuous MJPEG with `IPU_RUNNER_MJPEG_PORT=0`. Signed readiness and HTTP
requests remain the Swift client's responsibility. A native `running` status
means the testServe lifecycle event was seen, not that an HTTP call succeeded.

Startup must reach the testServe event within 90 seconds. Afterward it lasts
only as long as its app owner and iOS execution budget permit. `stop` does not
revoke actions already accepted by XCTest, and no error automatically retries
an action or starts a second test session.

## Source provenance

`vendor/idevice` is the `idevice/` package from
[jkcoxson/idevice at 3854a5df4a5a6dee71ffce4d8befc2ea356a8065](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice),
under the retained `vendor/idevice/LICENSE.txt` (MIT). No StikDebug Swift source
or opaque binary is included. The only upstream implementation change is
`services/dvt/xctest/mod.rs`, recorded in `patches/xctest-rsd.patch`:

- optional explicit product module in TestConfig;
- `run_rsd` accepts an existing authenticated adapter/RSD directory;
- existing runner orchestration moved into a shared private helper, so the
  original provider entry and new entry execute the same testmanager protocol.

`source-manifest.json` records the upstream package tree and local patch hash.
The patch adds no secondary transport fallback. The reviewed feature set is
`ring`, `tcp`, `remote_pairing`, and `xctest` and their required dependencies.

Host tests verify the real test-bundle/config path, injected token and disabled
video stream, rejection of invalid input without connecting, redacted status,
startup timeout, late callback cancellation, and closing a real local socket
blocked in pair-verify when the owner is freed. These are lifecycle/contract
tests, not true-device or iOS background acceptance.
