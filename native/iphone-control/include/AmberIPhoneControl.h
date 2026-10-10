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

/// Explicit first setup: ask iOS to create a NEW development pairing through
/// its normal system consent flow. Does not launch or control any application.
/// NULL endpoint selects 127.0.0.1:49152. Same handle/status/stop/free lifecycle.
/// Pairing-only phases include pairing_handshake, verifying_pairing,
/// waiting_for_consent and terminal paired.
/// Times out after 90 seconds; a rejection is never automatically retried.
AmberIPhoneControlHandle *amber_iphone_control_pairing_start(const char *endpoint);

/// Private XML result only when phase == paired; otherwise NULL. No file is
/// written by Rust. Caller may explicitly save to local Keychain, never logs,
/// chat or sync. Free this owned copy using amber_iphone_control_string_free.
char *amber_iphone_control_pairing_copy_plist(const AmberIPhoneControlHandle *handle);

/// Snapshot: {phase, code, message, native_error_code, native_error_subcode,
/// native_io_kind, native_os_error_code, pair_verify_error}. Optional diagnostics
/// contain only stable error numbers/standard IO variants, never remote text.
/// Phases: connecting, pairing, tunnel, discovering, starting, running,
/// stopping, stopped, failed. "running" is the testServe start event, NOT HTTP readiness.
/// The caller must free this owned string with amber_iphone_control_string_free.
char *amber_iphone_control_status_json(const AmberIPhoneControlHandle *handle);

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
