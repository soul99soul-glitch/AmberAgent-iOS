#ifndef AMBER_IPHONE_CONTROL_H
#define AMBER_IPHONE_CONTROL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmberIPhoneControlHandle AmberIPhoneControlHandle;

/// Copies every input before returning. No network operation runs on this thread.
/// Pairing must be an existing RemotePairing plist; no pair-setup is attempted.
/// endpoint is an IP:port, e.g. "10.7.0.1:49152" (NULL selects that default).
/// module is the built PRODUCT_MODULE_NAME, e.g. "iPhoneUse".
/// token is 32..128 ASCII hex chars. Each launch must use a new random token.
/// Always returns an owned handle, including invalid-input failures observable
/// with status_json. Call stop before dropping the task owner and free once.
AmberIPhoneControlHandle *amber_iphone_control_start(
    const uint8_t *pairing, size_t pairing_length,
    const char *endpoint, const char *runner_bundle_id,
    const char *test_module_name, const char *runner_token);

/// One read-only installed-app query through the verified RemotePairing/RSD
/// connection. Copies inputs, never starts XCTest or activates an application.
/// NULL endpoint selects 10.7.0.1:49152. Existing pairing only; no pair-setup.
/// Has a 30-second deadline and uses the same status/stop/free lifecycle.
AmberIPhoneControlHandle *amber_iphone_control_apps_start(
    const uint8_t *pairing, size_t pairing_length, const char *endpoint);

/// Copies this handle's normalized catalog; never starts I/O. Available on
/// standalone app-query and control handles (the latter caches it at startup).
/// JSON: {state:"pending"}, {state:"ready",apps:[{bundleID,name,isSystem?}]},
/// or {state:"failed",error:{phase,code,message,...fixed native diagnostics}}.
/// Query failures stay visible even when the control session is otherwise ready.
/// Names are display name, bundle name, then bundle ID; no raw Info.plist fields.
/// Free this owned string using amber_iphone_control_string_free.
char *amber_iphone_control_apps_copy_json(const AmberIPhoneControlHandle *handle);

/// Explicit first setup: ask iOS to create a NEW development pairing through
/// its normal system consent flow. Does not launch or control any application.
/// NULL endpoint selects 127.0.0.1:49152. Same handle/status/stop/free lifecycle.
/// Pairing-only phases include pairing_handshake, verifying_pairing,
/// waiting_for_consent and terminal paired.
/// Times out after 90 seconds; a rejection is never automatically retried.
AmberIPhoneControlHandle *amber_iphone_control_pairing_start(const char *endpoint);

/// One credential-free greeting through the same transport as control start.
/// Explicit numeric endpoint required; NULL is rejected. Stops after the greeting
/// or an 8-second deadline. Never verifies/creates pairing, tunnels, or XCTest.
/// Success is terminal phase=stopped, code=handshake_ok. Same stop/free lifecycle.
AmberIPhoneControlHandle *amber_iphone_control_inspect_handshake(const char *endpoint);

/// Diagnostic-only credential-free greeting using the current VPN route.
/// Explicit numeric IPv4:port required; NULL, names, IPv6 and zero port rejected.
/// UDP connect/local_addr selects the kernel source without sending a payload;
/// that source must match one UP utun with a valid index. The actual TCP socket
/// is bound to that interface; there is no Wi-Fi, cellular or loopback fallback.
/// Never starts a VPN or verifies/creates pairing, tunnels, or XCTest. Does not
/// change the production control transport. Same 8-second deadline and
/// status/stop/free lifecycle; success is phase=stopped, code=handshake_ok.
AmberIPhoneControlHandle *amber_iphone_control_inspect_routed_handshake(const char *endpoint);

/// One credential-free QueryType request to an explicit IPv4:62078 endpoint.
/// NULL, names, IPv6 and other ports are rejected. Stops after the response or
/// an 8-second deadline. No pairing, StartSession, service startup or tunnel.
/// Success validates Type=com.apple.mobile.lockdown and is terminal
/// phase=stopped, code=lockdown_query_ok. Same status/stop/free lifecycle.
AmberIPhoneControlHandle *amber_iphone_control_inspect_lockdown(const char *endpoint);

/// Private XML result only when phase == paired; otherwise NULL. No file is
/// written by Rust. Caller may explicitly save to local Keychain, never logs,
/// chat or sync. Free this owned copy using amber_iphone_control_string_free.
char *amber_iphone_control_pairing_copy_plist(const AmberIPhoneControlHandle *handle);

/// Snapshot: {phase, code, message, native_error_code, native_error_subcode,
/// native_io_kind, native_os_error_code, native_transport_stage, pair_verify_error}. Optional diagnostics
/// contain only stable error numbers/standard IO variants/fixed last-transport stages,
/// never remote text. A stage is the last operation, including verify cleanup writes.
/// Phases: connecting, pairing, tunnel, discovering, starting, running,
/// stopping, stopped, failed. "running" is the testServe start event, NOT HTTP readiness.
/// The caller must free this owned string with amber_iphone_control_string_free.
char *amber_iphone_control_status_json(const AmberIPhoneControlHandle *handle);

/// Creates one temporary in-memory pairable-host identity for the formal app
/// to publish over Bonjour. This does not bind a socket, publish Bonjour,
/// access Keychain, create an RPPairing file, or start pairing. The JSON has
/// only `service_identifier` and a `txt_records` string dictionary. Caller
/// owns the returned string and must free it with amber_iphone_control_string_free.
char *amber_iphone_control_self_discovery_info(void);

/// Nonblocking, idempotent cancellation. Does not undo executed device actions.
void amber_iphone_control_stop(const AmberIPhoneControlHandle *handle);

/// Stops and joins the session runtime, closing all session-owned child tasks.
/// Invoke off the UI thread. Do not use handle after this call or call concurrently
/// with any operation on the same handle. stop/status may run concurrently.
void amber_iphone_control_free(AmberIPhoneControlHandle *handle);
void amber_iphone_control_string_free(char *text);

#ifdef __cplusplus
}
#endif
#endif
