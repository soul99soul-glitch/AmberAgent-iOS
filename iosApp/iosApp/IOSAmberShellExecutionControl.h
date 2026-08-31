#ifndef IOS_AMBER_SHELL_EXECUTION_CONTROL_H
#define IOS_AMBER_SHELL_EXECUTION_CONTROL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmberShellExecutionControl AmberShellExecutionControl;

typedef enum AmberShellExecutionState {
    AmberShellExecutionStateRunning = 0,
    AmberShellExecutionStateCancelled = 1,
    AmberShellExecutionStateTimedOut = 2,
} AmberShellExecutionState;

/*
 * Creates a per-execution control object. The timeout is measured from this
 * call using the monotonic clock. A non-positive timeout expires at the first
 * checkpoint; positive infinity represents a deadline that will not expire.
 * NaN and allocation/clock failures return NULL.
 */
AmberShellExecutionControl *amber_shell_execution_control_create(
    double timeout_seconds);

void amber_shell_execution_control_destroy(
    AmberShellExecutionControl *control);

/* Returns non-zero only when this call wins the running -> cancelled race. */
int amber_shell_execution_control_cancel(
    AmberShellExecutionControl *control);

/*
 * Checks the monotonic deadline and returns the first terminal state. A
 * running control becomes timed_out when its deadline has passed. Cancellation
 * and timeout use an atomic compare-and-exchange, so exactly one wins.
 */
AmberShellExecutionState amber_shell_execution_control_checkpoint(
    AmberShellExecutionControl *control);

/* Reads the current state without checking the clock. */
AmberShellExecutionState amber_shell_execution_control_state(
    const AmberShellExecutionControl *control);

#ifdef __cplusplus
}
#endif

#endif /* IOS_AMBER_SHELL_EXECUTION_CONTROL_H */
