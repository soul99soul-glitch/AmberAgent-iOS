#include "IOSAmberShellExecutionControl.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

enum {
    AMBER_SHELL_EXECUTION_STATE_RUNNING = AmberShellExecutionStateRunning,
    AMBER_SHELL_EXECUTION_STATE_CANCELLED = AmberShellExecutionStateCancelled,
    AMBER_SHELL_EXECUTION_STATE_TIMED_OUT = AmberShellExecutionStateTimedOut,
};

struct AmberShellExecutionControl {
    _Atomic uint32_t state;
    uint64_t deadline_ns;
};

static int amber_shell_execution_monotonic_now(uint64_t *destination) {
    if (destination == NULL) {
        return -1;
    }

    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
        now.tv_sec < 0 || now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) {
        return -1;
    }

    uint64_t seconds = (uint64_t)now.tv_sec;
    if (seconds > UINT64_MAX / UINT64_C(1000000000)) {
        *destination = UINT64_MAX;
        return 0;
    }

    uint64_t nanoseconds =
        seconds * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    if (nanoseconds < seconds * UINT64_C(1000000000)) {
        *destination = UINT64_MAX;
        return 0;
    }

    *destination = nanoseconds;
    return 0;
}

static uint64_t amber_shell_execution_deadline(
    uint64_t now_ns,
    double timeout_seconds) {
    if (timeout_seconds <= 0.0) {
        return now_ns;
    }

    if (timeout_seconds != timeout_seconds || /* NaN, guarded by create. */
        timeout_seconds >= (double)UINT64_MAX) {
        return UINT64_MAX;
    }

    long double timeout_ns = (long double)timeout_seconds * 1000000000.0L;
    long double available_ns = (long double)(UINT64_MAX - now_ns);
    if (timeout_ns >= available_ns) {
        return UINT64_MAX;
    }

    return now_ns + (uint64_t)timeout_ns;
}

AmberShellExecutionControl *amber_shell_execution_control_create(
    double timeout_seconds) {
    if (timeout_seconds != timeout_seconds) {
        return NULL;
    }

    uint64_t now_ns = 0;
    if (amber_shell_execution_monotonic_now(&now_ns) != 0) {
        return NULL;
    }

    AmberShellExecutionControl *control =
        (AmberShellExecutionControl *)malloc(sizeof(*control));
    if (control == NULL) {
        return NULL;
    }

    atomic_init(&control->state, AMBER_SHELL_EXECUTION_STATE_RUNNING);
    control->deadline_ns = amber_shell_execution_deadline(now_ns, timeout_seconds);
    return control;
}

void amber_shell_execution_control_destroy(
    AmberShellExecutionControl *control) {
    free(control);
}

int amber_shell_execution_control_cancel(
    AmberShellExecutionControl *control) {
    if (control == NULL) {
        return 0;
    }

    /* Claim an expired deadline before competing with it for terminal state. */
    if (amber_shell_execution_control_checkpoint(control) !=
        AmberShellExecutionStateRunning) {
        return 0;
    }

    uint32_t expected = AMBER_SHELL_EXECUTION_STATE_RUNNING;
    return atomic_compare_exchange_strong_explicit(
               &control->state,
               &expected,
               AMBER_SHELL_EXECUTION_STATE_CANCELLED,
               memory_order_acq_rel,
               memory_order_acquire)
        ? 1
        : 0;
}

AmberShellExecutionState amber_shell_execution_control_checkpoint(
    AmberShellExecutionControl *control) {
    if (control == NULL) {
        return AmberShellExecutionStateRunning;
    }

    uint32_t observed = atomic_load_explicit(&control->state, memory_order_acquire);
    if (observed != AMBER_SHELL_EXECUTION_STATE_RUNNING) {
        return (AmberShellExecutionState)observed;
    }

    uint64_t now_ns = 0;
    if (control->deadline_ns != UINT64_MAX &&
        amber_shell_execution_monotonic_now(&now_ns) == 0 &&
        now_ns >= control->deadline_ns) {
        uint32_t expected = AMBER_SHELL_EXECUTION_STATE_RUNNING;
        atomic_compare_exchange_strong_explicit(
            &control->state,
            &expected,
            AMBER_SHELL_EXECUTION_STATE_TIMED_OUT,
            memory_order_acq_rel,
            memory_order_acquire);
        observed = atomic_load_explicit(&control->state, memory_order_acquire);
    }

    return (AmberShellExecutionState)observed;
}

AmberShellExecutionState amber_shell_execution_control_state(
    const AmberShellExecutionControl *control) {
    if (control == NULL) {
        return AmberShellExecutionStateRunning;
    }

    return (AmberShellExecutionState)atomic_load_explicit(
        &control->state,
        memory_order_acquire);
}
