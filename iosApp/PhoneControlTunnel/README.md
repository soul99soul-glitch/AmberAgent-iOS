# Phone-control local connection

The host embeds this NetworkExtension in both app variants. The provider has
no dependency on KMP, Rust, the runner, pairing files, or a remote server.

- Interface: `10.7.1.1/32`, matching the proven LocalDevVPN address plan.
- Included route: `10.7.0.1/32`; the default route is excluded.
- No DNS settings, IPv6 route, or network-wide route is configured.
- Only IPv4 packets from `10.7.1.1` to `10.7.0.1` are reflected.
- Stop invalidates queued reads and pending network-settings completion.

`Fixtures/main.swift` validates packet address and checksum preservation,
options/fragments, and rejection of unrelated or malformed packets:

```sh
swiftc iosApp/PhoneControlTunnel/LocalPacketReflection.swift \
  iosApp/PhoneControlTunnel/Fixtures/main.swift -o /tmp/amber-packet-fixture
/tmp/amber-packet-fixture
```

The fixtures do not prove signing, iOS VPN approval, service handshake, or
runner execution. Those require the embedded extension on the physical phone.
See `NOTICE.txt` for upstream attribution.

## Integration gate (2026-10-11)

`PhoneControlRuntime/PhoneControlLocalTunnel.swift` owns Amber's one VPN
configuration. Preparation saves it; a later start waits for NE's connected
state. Its owner-scoped stop reports the actual disconnected state. The caller
must finish runner shutdown and native handle cleanup before stopping it.

The launch-only `-amber-phone-embedded-tunnel-inspection-once` entry prepares the
configuration, starts it, runs a credential-free RemotePairing greeting, and
stops it. First preparation requires iOS's VPN confirmation. It does not read
pairing credentials or start a runner.

The current source integrates the manager into control startup, first pairing,
and standalone app queries. The settings page prepares the configuration and
shows its real state; asynchronous background completion waits for cleanup.
Each stop receipt belongs to the stopped owner, even if a new task claims the
controller before the receipt consumer resumes.

The signed phase-2 Release build passed after developer account login. Both
host and extension signatures, packet-tunnel entitlements, and device profiles
were verified. The first iOS configuration is now saved. A configured launch
completed the credential-free greeting and confirmed disconnection.

The integrated phase-3 signed Release was then installed in place; conversation
metadata was preserved. Device checks queried 138 apps, exercised search/add
and restored names/scope in a disposable preferences suite, then restarted the
connection for authenticated runner readiness and a 189-node UI tree. Native
shutdown and tunnel disconnection completed. The first model-driven popup test
missed the close target; its completed dispatch receipt is not a successful close.
A separate stale-background-checkpoint alert was reproduced and repaired. The
final signed fix passed 29 regression tests and independent review. After USB
reconnected, it was installed with all 362 conversation-file and 3 App Group-file
metadata records preserved. Cold launch cleared eight old checkpoints without
changing their ledger terminals or corresponding transcripts.

A subsequent connection failure was reproduced: both the embedded tunnel and
LocalDevVPN returned TCP connection refused before the greeting.
USB packet-header capture confirms the SYN is reflected into the phone and a
RST/ACK comes back from port 49152. This confirms packet delivery for that attempt,
not why iOS rejected it. The trusted USB service still accepted its greeting.
After the user connected usable Wi-Fi, the same installed version and pairing
completed the greeting, authenticated runner startup, a 187-node tree read and
cleanup. A subsequent model task launched and observed Meituan, then stopped
with complete cleanup and no retained checkpoint. Its opening ad expired before
the attempted tap; the coupon popup was absent, so precise popup closing remains
unverified. No transport or runner changes were needed for this network-state
recovery. This does not establish universal cellular incompatibility or iOS's
internal listener rules. See the delivery evidence.
