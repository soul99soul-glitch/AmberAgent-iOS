#ifndef AMBER_SHELL_PYTHON_BRIDGE_H
#define AMBER_SHELL_PYTHON_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#include "../iosApp/IOSAmberShellExecutionControl.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AMBER_SHELL_PYTHON_MAX_STDIN_BYTES = 64 * 1024,
    AMBER_SHELL_PYTHON_MAX_OUTPUT_BYTES = 128 * 1024,
};

typedef struct AmberShellPythonBridgeResult {
    int32_t exit_code;
    uint8_t *stdout_bytes;
    size_t stdout_length;
    uint8_t *stderr_bytes;
    size_t stderr_length;
    char *error_message;
} AmberShellPythonBridgeResult;

/*
 * Initializes CPython on the first call and reuses that interpreter for the
 * lifetime of the process. Calls are serialized by the implementation. When
 * control is non-NULL, the call observes its per-execution cancellation and
 * monotonic deadline while Python bytecode is running.
 *
 * resource_path is the bundle resource root. The bridge expects the CPython
 * home at resource_path/python and the helper app at app_path.
 */
int amber_shell_python_execute(
    const char *resource_path,
    const char *app_path,
    const uint8_t *source_bytes,
    size_t source_length,
    const uint8_t *stdin_bytes,
    size_t stdin_length,
    AmberShellExecutionControl *control,
    AmberShellPythonBridgeResult *result);

void amber_shell_python_execution_result_dispose(
    AmberShellPythonBridgeResult *result);

#ifdef __cplusplus
}
#endif

#endif /* AMBER_SHELL_PYTHON_BRIDGE_H */
