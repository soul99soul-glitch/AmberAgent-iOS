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
when available. Amber also opts into fixed framing-stage diagnostics
(`serialize_request`, `write_frame`, `flush_frame`, `read_magic`, `validate_magic`,
`read_length`, `read_body`, `decode_body`, `response_received`) and rejects a non-`RPPairing` magic before reading its length.
No response bytes are retained in diagnostics. Pair-verify failures retain the
same redacted fields.
A stage denotes the last transport operation, including a verify-rejection cleanup
write; it does not imply that a consent prompt was presented.
Untrusted protocol error text is not surfaced. The session disables upstream tracing on its own runtime thread
because upstream pairing parsing logs private plist contents at debug level.

The control-start entry verifies existing RemotePairing material only. It
deliberately does not call the upstream `connect` convenience method that falls
back to creating a new pairing. A rejected pairing is an actionable failure.

Explicit first preparation uses the separate `pairing_start` entry point. It
implements upstream's documented iOS network pair-setup (`pair_rsd_ios.rs`
`wifi_pair_flow`): new local identity → RemotePairing handshake → system
consent → SRP verification → save peer record. Only a typed `PairVerifyFailed`
response permits setup; transport and protocol failures stop before consent.
It never launches an app. The
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

The control-start ABI defaults to `10.7.0.1:49152`, matching Amber's embedded
local tunnel and the previously verified LocalDevVPN address plan. Other explicit endpoints remain available for protocol diagnostics.
The first-preparation C ABI retains its legacy null default `127.0.0.1:49152`;
the formal Swift caller explicitly supplies this local tunnel peer. The library never
installs or changes VPN/network settings. Neither endpoint's TCP availability
proves pairing or automation authorization.

## Credential-free direct-route diagnostics

`amber_iphone_control_inspect_handshake` accepts explicit numeric endpoints,
including scoped IPv6 in the form `[fe80::1%4]:49152` (the scope is a numeric
interface index). It performs only the RemotePairing greeting. A successful
greeting does not prove later pairing or TLS tunnel connectivity.

`amber_iphone_control_inspect_lockdown` accepts only explicit `IPv4:62078` and
uses a direct TCP socket without the local tunnel route helper. It reuses
`Idevice::get_type` to send exactly one `QueryType`, accepts only
`com.apple.mobile.lockdown`, then closes the socket. It does not access pairing
material, start a Lockdown session or service, create a tunnel, or launch XCTest.
Success is terminal `phase=stopped, code=lockdown_query_ok`; failures retain only
fixed `lockdown_connect`, `lockdown_query_type`, or `lockdown_validate_type`
stages and the existing numeric/I/O diagnostics. The shared 8-second deadline
returns `startup_timeout` with stage `lockdown_inspection`. Stop/free cancel
pending I/O through the existing owned-runtime lifecycle. This diagnostic proves
only that the queried endpoint answered as Lockdown, not that a trusted session
or CoreDeviceProxy will work.

## Installed application discovery

`amber_iphone_control_apps_start` uses the same verified RemotePairing, TLS-PSK
tunnel and RSD connection as control startup, but stops after InstallationProxy
`Lookup`. It neither starts XCTest nor activates a target application. The
standalone operation has a 30-second deadline and the existing stop/free lifecycle.
The Swift `PhoneControlApplications` owner cancels pending reads and joins the
native runtime before returning from cancellation.

The lookup requests only bundle identifier, display/bundle name, application type
and explicit hidden/helper/extension markers. Results contain `bundleID`, `name`
and optional `isSystem`; a missing name falls back to the bundle ID. Entries with
explicit `hidden` app tags, `LSBackgroundOnly`, `LSUIElement` or `NSExtension`
metadata are excluded. Missing markers, background capability declarations and
bundle prefixes do not imply that an application is hidden. This catalog is not
a guarantee that iOS will allow every listed application to launch.

Control startup also queries the catalog on its existing InstallationProxy
connection before launching XCTest. The bounded lookup result is cached on that
native handle; catalog failure stays separate from control-session readiness.
`amber_iphone_control_apps_copy_json` reads this cache without opening another
tunnel. Standalone and control handles use the same result contract:
`pending`, `ready` with an `apps` array (including a successful empty array), or
`failed` with fixed diagnostic fields. Raw Info.plist data, container paths,
entitlements and credentials are never exported through this API or logs.
During an active control session callers must read its cache; a still-pending
cache must not trigger a second discovery connection.

## Temporary pairable-host advertisement material

`amber_iphone_control_self_discovery_info` is a pure in-memory preparation
helper for the formal app's one-shot iOS 27 pairable-host discovery probe. It
reuses the pinned vendor `PairableHostInfo::generate("Amber 同机验证", "Mac17,7")`
and `mdns_txt_records` APIs, returning owned JSON with only:

```json
{
  "service_identifier": "<fresh UUID>",
  "txt_records": {
    "name": "Amber 同机验证",
    "identifier": "<same UUID>",
    "authTag": "<base64 6-byte tag>",
    "model": "Mac17,7",
    "flags": "1",
    "ver": "26",
    "minVer": "17"
  }
}
```

Each call creates a fresh temporary identifier and host `altIRK` in memory.
The helper does not bind a socket, publish Bonjour, access Keychain, create an
`RpPairingFile`, start SRP, display a PIN, or write any pairing material. The
formal app owns the fixed service type
`_remotepairing-pairable-host._tcp.` and must free the returned JSON with
`amber_iphone_control_string_free`.

The installed runner executable and supplied module must agree. For the pinned
iphone-use runner: bundle `app.amber.selfcontrol.runner.xctrunner`, executable
`iPhoneUse-Runner`, module `iPhoneUse`, plugin `iPhoneUse.xctest`, filter
`iPhoneUse.RunnerTests/testServe`. Launch injects `IPU_RUNNER_TOKEN` and disables
continuous MJPEG with `IPU_RUNNER_MJPEG_PORT=0`. Signed readiness and HTTP
requests remain the Swift client's responsibility. After authenticated readiness,
the Swift owner sends a signed, two-second-bounded `/shutdown` before closing
DTX; a failed acknowledgement remains visible in its stopped status. A native `running` status
means the testServe lifecycle event was seen, not that an HTTP call succeeded.
Phase changes and a test-start method-match boolean are emitted as fixed console
metadata; raw event payloads, method names, credentials and UI text are not logged.

Startup must reach the testServe event within 90 seconds. Afterward it lasts
only as long as its app owner and iOS execution budget permit. `stop` does not
revoke actions already accepted by XCTest, and no error automatically retries
an action or starts a second test session.

## Source provenance

`vendor/idevice` is the `idevice/` package from
[jkcoxson/idevice at 3854a5df4a5a6dee71ffce4d8befc2ea356a8065](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice),
under the retained `vendor/idevice/LICENSE.txt` (MIT). No StikDebug Swift source
or opaque binary is included. The XCTest adaptation in
`services/dvt/xctest/mod.rs` is recorded in
`patches/xctest-rsd.patch`:

- optional explicit product module in TestConfig;
- `run_rsd` accepts an existing authenticated adapter/RSD directory;
- existing runner orchestration moved into a shared private helper, so the
  original provider entry and new entry execute the same testmanager protocol.

`remote_pairing/socket.rs` adds opt-in framing diagnostics and magic validation,
recorded in `patches/rppairing-diagnostics.patch`. Existing upstream constructors
keep their prior behavior; both Amber pairing entries explicitly enable this path.

`patches/xctest-identifier-decoding.patch` resolves the modern XCTest identifier
component array through its NSKeyedArchive object references. The pinned generic
decoder leaves unknown XCTest objects unresolved, which previously delivered an
empty method to the readiness listener even after the phone started `testServe`.
The specialized decoder is shared by identifier lifecycle callbacks and tested
through the actual dispatcher with a binary object-pool fixture.

`patches/installation-proxy-attributes.patch` adds an explicit attribute projection
to InstallationProxy Lookup. Existing `get_apps` callers delegate with no projection,
preserving the runner metadata request and upstream defaults. Wire fixtures cover
both the restricted catalog query and the existing full-metadata API.

`source-manifest.json` records the upstream package tree and local patch hashes.
The patch adds no secondary transport fallback. The reviewed feature set is
`ring`, `tcp`, `remote_pairing`, and `xctest` and their required dependencies.

Host tests verify the real test-bundle/config path, injected token and disabled
video stream, rejection of invalid input without connecting, redacted status,
startup timeout, late callback cancellation, and closing a real local socket
blocked in pair-verify when the owner is freed. These are lifecycle/contract
tests, not true-device or iOS background acceptance.


## Credential-free handshake diagnosis

`amber_iphone_control_inspect_handshake` requires an explicit numeric endpoint
and shares the control-start greeting implementation. It sends one greeting,
then closes the socket; it does not load or verify pairing material, run setup,
create a tunnel, or start XCTest. The owned runtime has an 8-second deadline.
Success is terminal `phase=stopped, code=handshake_ok`; errors retain the existing
redacted transport diagnostics. Use the normal stop/free lifecycle.

The formal app exposes this only through the exact launch argument
`-amber-phone-handshake-inspection-once`. It uses the existing local tunnel
route and logs fixed status metadata. Normal launches, the model, and settings
do not trigger it.

## Same-device local tunnel

The formal app uses the local tunnel peer `10.7.0.1:49152`. On Apple
platforms, every TCP socket to that peer, including the dynamically assigned
TLS port, requires exactly one up `utun` interface with address `10.7.1.1`.
`IP_BOUND_IF` binds the actual socket before connect. Missing, ambiguous or
unusable interfaces stop startup; the route never falls back to ordinary LAN.
Other explicit endpoints retain their existing behavior for diagnostics and
local protocol tests. Pairing verification still authenticates the service;
the interface match alone is not an authentication result.

The previously delivered route uses the separately installed
[LocalDevVPN af3fd697](https://github.com/jkcoxson/LocalDevVPN/tree/af3fd697803ada4ac2b8d518358f5ab0a534844c).
The current source integrates Amber's own packet-tunnel extension and host manager
for control, pairing, and standalone app queries. The host creates its own
configuration on explicit first preparation, starts it before native work, and
waits for native shutdown before disconnecting. It requires one iOS system VPN
confirmation. The Rust library itself still does not manage VPN settings.
The integrated signed extension has passed configuration reuse, greeting,
application discovery, authenticated runner startup, UI-tree reading and
disconnection on the physical device. The first model-driven popup-close test
missed its visual target; a completed action receipt is not business acceptance.
The final host cleanup fix has now been installed and its eight-checkpoint
cleanup verified on the device without changing existing terminal records or
their transcripts. A later connection-refused failure was reproduced before
greeting, pairing or runner startup on both embedded and external local tunnels;
packet headers showed a reflected SYN followed by a RST/ACK from port 49152.
Connecting usable Wi-Fi restored the same installed version's greeting,
authenticated runner, 187-node tree read and cleanup, without changing pairing
or code. A subsequent model task also launched/read Meituan and stopped cleanly.
The relevant coupon popup was absent, so exact popup closing remains unverified.
The exact iOS listener rule and broader cellular support are not established. See
`iosApp/PhoneControlTunnel/README.md` for attribution and the delivery gate.
Bonjour inspection remains a read-only settings diagnostic.

The formal app's separate exact launch argument
`-amber-phone-readiness-inspection-once` checks the authenticated pipeline.
It loads existing Keychain material, creates a phone-owned session scoped to
`app.amber.ios`, reads signed status and at most 200 UI nodes, then closes the
session. It does not dispatch actions, call a model, change the user's grant,
create pairing material or install a runner. Logs contain fixed status fields
and counts, never UI text or credentials. This delivery diagnostic does not
prove a normal chat's cross-app action flow or background continuity.
