#import "AmberShellPythonBridge.h"

#import <Python/Python.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/*
 * CPython is process-global in this bridge. The actor on the Swift side is
 * the normal serialization boundary; this lock also keeps the C entry point
 * correct if it is called from another Objective-C consumer.
 */
static pthread_mutex_t amber_shell_python_mutex = PTHREAD_MUTEX_INITIALIZER;
static int amber_shell_python_initialization_attempted = 0;
static int amber_shell_python_initialized = 0;
static char *amber_shell_python_initialization_error = NULL;
static PyObject *amber_shell_python_helper_module = NULL;
static PyObject *amber_shell_python_helper_execute = NULL;
static _Thread_local AmberShellExecutionControl *amber_shell_python_trace_control = NULL;

static char *amber_shell_python_strdup(const char *value) {
    if (value == NULL) {
        return NULL;
    }

    size_t length = strlen(value);
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, length + 1);
    return copy;
}

static void amber_shell_python_set_error(
    AmberShellPythonBridgeResult *result,
    const char *message,
    int32_t exit_code) {
    if (result == NULL) {
        return;
    }

    result->exit_code = exit_code;
    free(result->error_message);
    result->error_message = amber_shell_python_strdup(message);
}

static void amber_shell_python_clear_output(
    AmberShellPythonBridgeResult *result) {
    if (result == NULL) {
        return;
    }

    free(result->stdout_bytes);
    result->stdout_bytes = NULL;
    result->stdout_length = 0;
    free(result->stderr_bytes);
    result->stderr_bytes = NULL;
    result->stderr_length = 0;
}

static int amber_shell_python_apply_control_state(
    AmberShellPythonBridgeResult *result,
    AmberShellExecutionState state) {
    const char *message = NULL;
    switch (state) {
        case AmberShellExecutionStateCancelled:
            message = "AmberShell Python execution was cancelled.";
            break;
        case AmberShellExecutionStateTimedOut:
            message = "AmberShell Python execution timed out.";
            break;
        case AmberShellExecutionStateRunning:
            return 0;
    }

    /* The native terminal state wins over a helper-level BaseException tuple. */
    PyErr_Clear();
    amber_shell_python_clear_output(result);
    /* Cancellation/timeout have no shell exit status; the owner reads state. */
    amber_shell_python_set_error(result, message, 0);
    return -1;
}

static int amber_shell_python_trace(
    PyObject *object,
    PyFrameObject *frame,
    int event,
    PyObject *argument) {
    (void)object;
    (void)frame;
    (void)event;
    (void)argument;

    AmberShellExecutionControl *control = amber_shell_python_trace_control;
    if (control == NULL) {
        return 0;
    }

    AmberShellExecutionState state =
        amber_shell_execution_control_checkpoint(control);
    switch (state) {
        case AmberShellExecutionStateCancelled:
            PyErr_SetString(
                PyExc_KeyboardInterrupt,
                "AmberShell Python execution was cancelled.");
            return -1;
        case AmberShellExecutionStateTimedOut:
            PyErr_SetString(
                PyExc_TimeoutError,
                "AmberShell Python execution timed out.");
            return -1;
        case AmberShellExecutionStateRunning:
            return 0;
    }
    return 0;
}

static void amber_shell_python_set_status_error(
    char **destination,
    PyStatus status) {
    if (destination == NULL) {
        return;
    }

    const char *message = status.err_msg;
    if (message == NULL || message[0] == '\0') {
        message = "CPython returned an unspecified configuration error.";
    }
    *destination = amber_shell_python_strdup(message);
}

static char *amber_shell_python_copy_exception(void) {
    PyObject *exception_type = NULL;
    PyObject *exception_value = NULL;
    PyObject *exception_traceback = NULL;
    PyObject *text = NULL;
    char *message = NULL;

    PyErr_Fetch(&exception_type, &exception_value, &exception_traceback);
    PyErr_NormalizeException(&exception_type, &exception_value, &exception_traceback);

    if (exception_value != NULL) {
        text = PyObject_Str(exception_value);
    }
    if (text == NULL && exception_type != NULL) {
        PyErr_Clear();
        text = PyObject_Str(exception_type);
    }
    if (text != NULL) {
        const char *utf8 = PyUnicode_AsUTF8(text);
        if (utf8 != NULL) {
            message = amber_shell_python_strdup(utf8);
        }
    }
    PyErr_Clear();

    Py_XDECREF(text);
    Py_XDECREF(exception_type);
    Py_XDECREF(exception_value);
    Py_XDECREF(exception_traceback);

    if (message == NULL) {
        message = amber_shell_python_strdup("Python raised an exception without a message.");
    }
    return message;
}

static char *amber_shell_python_join_path(const char *root, const char *suffix) {
    if (root == NULL || suffix == NULL) {
        return NULL;
    }

    size_t root_length = strlen(root);
    size_t suffix_length = strlen(suffix);
    int needs_separator = root_length > 0 && root[root_length - 1] != '/';
    size_t length = root_length + (size_t)needs_separator + suffix_length;
    char *path = (char *)malloc(length + 1);
    if (path == NULL) {
        return NULL;
    }

    memcpy(path, root, root_length);
    if (needs_separator) {
        path[root_length] = '/';
    }
    memcpy(path + root_length + (size_t)needs_separator, suffix, suffix_length);
    path[length] = '\0';
    return path;
}

static int amber_shell_python_append_path(
    PyConfig *config,
    const char *path,
    char **error_message) {
    wchar_t *wide_path = Py_DecodeLocale(path, NULL);
    if (wide_path == NULL) {
        if (error_message != NULL) {
            *error_message = amber_shell_python_strdup(
                "Unable to decode a CPython bundle path as UTF-8.");
        }
        return -1;
    }

    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide_path);
    PyMem_RawFree(wide_path);
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(error_message, status);
        return -1;
    }
    return 0;
}

static int amber_shell_python_initialize_locked(
    const char *resource_path,
    const char *app_path) {
    if (amber_shell_python_initialization_attempted) {
        return amber_shell_python_initialized ? 0 : -1;
    }
    amber_shell_python_initialization_attempted = 1;

    if (resource_path == NULL || resource_path[0] == '\0' ||
        app_path == NULL || app_path[0] == '\0') {
        amber_shell_python_initialization_error = amber_shell_python_strdup(
            "CPython bundle and AmberShell Python app paths are required.");
        return -1;
    }

    char *python_home = amber_shell_python_join_path(resource_path, "python");
    char *stdlib_path = amber_shell_python_join_path(resource_path, "python/lib/python3.14");
    char *dynload_path = amber_shell_python_join_path(
        resource_path,
        "python/lib/python3.14/lib-dynload");
    if (python_home == NULL || stdlib_path == NULL || dynload_path == NULL) {
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        amber_shell_python_initialization_error = amber_shell_python_strdup(
            "Unable to allocate CPython bundle paths.");
        return -1;
    }

    PyPreConfig preconfig;
    PyConfig config;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);

    /* Isolated, UTF-8, no process environment or user site configuration. */
    preconfig.isolated = 1;
    preconfig.use_environment = 0;
    preconfig.utf8_mode = 1;

    config.isolated = 1;
    config.use_environment = 0;
    config.user_site_directory = 0;
    config.site_import = 0;
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.configure_c_stdio = 1;
    config.install_signal_handlers = 0;
    config.safe_path = 1;
    config.parse_argv = 0;
    config.module_search_paths_set = 1;

    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    status = PyConfig_SetBytesString(&config, &config.program_name, "AmberShellPython");
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    status = PyConfig_SetBytesString(&config, &config.stdio_encoding, "utf-8");
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }
    status = PyConfig_SetBytesString(&config, &config.stdio_errors, "backslashreplace");
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    if (amber_shell_python_append_path(&config, app_path,
                                       &amber_shell_python_initialization_error) != 0 ||
        amber_shell_python_append_path(&config, stdlib_path,
                                       &amber_shell_python_initialization_error) != 0 ||
        amber_shell_python_append_path(&config, dynload_path,
                                       &amber_shell_python_initialization_error) != 0) {
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    char *argv[] = {(char *)"amber-shell-python"};
    status = PyConfig_SetBytesArgv(&config, 1, argv);
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        PyConfig_Clear(&config);
        free(python_home);
        free(stdlib_path);
        free(dynload_path);
        return -1;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    free(python_home);
    free(stdlib_path);
    free(dynload_path);
    if (PyStatus_Exception(status)) {
        amber_shell_python_set_status_error(&amber_shell_python_initialization_error, status);
        return -1;
    }

    amber_shell_python_helper_module = PyImport_ImportModule("amber_shell_python");
    if (amber_shell_python_helper_module == NULL) {
        amber_shell_python_initialization_error = amber_shell_python_copy_exception();
        PyEval_SaveThread();
        return -1;
    }

    amber_shell_python_helper_execute = PyObject_GetAttrString(
        amber_shell_python_helper_module,
        "execute");
    if (amber_shell_python_helper_execute == NULL ||
        !PyCallable_Check(amber_shell_python_helper_execute)) {
        PyErr_Clear();
        amber_shell_python_initialization_error = amber_shell_python_strdup(
            "AmberShell Python helper does not expose a callable execute function.");
        PyEval_SaveThread();
        return -1;
    }

    amber_shell_python_initialized = 1;
    /*
     * Py_InitializeFromConfig leaves the GIL owned by this OS thread. Swift
     * actors may resume later calls on another thread, so release it here and
     * let every execution acquire it through PyGILState_Ensure.
     */
    PyEval_SaveThread();
    return 0;
}

static int amber_shell_python_copy_unicode(
    PyObject *value,
    uint8_t **destination,
    size_t *destination_length) {
    if (destination == NULL || destination_length == NULL) {
        return -1;
    }
    *destination = NULL;
    *destination_length = 0;

    if (!PyUnicode_Check(value)) {
        return -1;
    }

    Py_ssize_t python_length = 0;
    const char *bytes = PyUnicode_AsUTF8AndSize(value, &python_length);
    if (bytes == NULL || python_length < 0) {
        return -1;
    }

    if ((size_t)python_length > AMBER_SHELL_PYTHON_MAX_OUTPUT_BYTES) {
        PyErr_SetString(
            PyExc_RuntimeError,
            "AmberShell Python helper exceeded the output limit.");
        return -1;
    }

    size_t safe_length = (size_t)python_length;
    if (safe_length == 0) {
        return 0;
    }

    uint8_t *copy = (uint8_t *)malloc(safe_length);
    if (copy == NULL) {
        return -1;
    }
    memcpy(copy, bytes, safe_length);
    *destination = copy;
    *destination_length = safe_length;
    return 0;
}

static int amber_shell_python_execute_locked(
    const uint8_t *source_bytes,
    size_t source_length,
    const uint8_t *stdin_bytes,
    size_t stdin_length,
    AmberShellExecutionControl *control,
    AmberShellPythonBridgeResult *result) {
    PyGILState_STATE gil_state = PyGILState_Ensure();
    PyObject *source = NULL;
    PyObject *input = NULL;
    PyObject *call_result = NULL;
    int return_code = -1;
    int trace_installed = 0;

    amber_shell_python_trace_control = NULL;
    if (control != NULL) {
        AmberShellExecutionState state =
            amber_shell_execution_control_checkpoint(control);
        if (amber_shell_python_apply_control_state(result, state) != 0) {
            goto cleanup;
        }
        amber_shell_python_trace_control = control;
        PyEval_SetTrace(amber_shell_python_trace, NULL);
        trace_installed = 1;
    }

    const char *source_buffer = source_bytes == NULL ? "" : (const char *)source_bytes;
    const char *stdin_buffer = stdin_bytes == NULL ? "" : (const char *)stdin_bytes;
    source = PyUnicode_DecodeUTF8(source_buffer, (Py_ssize_t)source_length, "strict");
    input = PyUnicode_DecodeUTF8(stdin_buffer, (Py_ssize_t)stdin_length, "strict");
    if (source == NULL || input == NULL) {
        char *message = amber_shell_python_copy_exception();
        amber_shell_python_set_error(result, message, 2);
        free(message);
        goto cleanup;
    }

    call_result = PyObject_CallFunctionObjArgs(
        amber_shell_python_helper_execute,
        source,
        input,
        NULL);
    if (call_result == NULL) {
        char *message = amber_shell_python_copy_exception();
        amber_shell_python_set_error(result, message, 74);
        free(message);
        goto cleanup;
    }
    if (!PyTuple_Check(call_result) || PyTuple_Size(call_result) != 3) {
        amber_shell_python_set_error(
            result,
            "AmberShell Python helper returned an invalid result.",
            74);
        goto cleanup;
    }

    PyObject *exit_value = PyTuple_GetItem(call_result, 0);
    PyObject *stdout_value = PyTuple_GetItem(call_result, 1);
    PyObject *stderr_value = PyTuple_GetItem(call_result, 2);
    long exit_code = PyLong_AsLong(exit_value);
    if (PyErr_Occurred() || exit_code < 0 || exit_code > INT32_MAX ||
        amber_shell_python_copy_unicode(
            stdout_value,
            &result->stdout_bytes,
            &result->stdout_length) != 0 ||
        amber_shell_python_copy_unicode(
            stderr_value,
            &result->stderr_bytes,
            &result->stderr_length) != 0) {
        if (result->stdout_bytes != NULL) {
            free(result->stdout_bytes);
            result->stdout_bytes = NULL;
            result->stdout_length = 0;
        }
        if (result->stderr_bytes != NULL) {
            free(result->stderr_bytes);
            result->stderr_bytes = NULL;
            result->stderr_length = 0;
        }
        char *message = amber_shell_python_copy_exception();
        if (message == NULL) {
            message = amber_shell_python_strdup(
                "AmberShell Python helper returned an invalid output.");
        }
        amber_shell_python_set_error(result, message, 74);
        free(message);
        goto cleanup;
    }

    result->exit_code = (int32_t)exit_code;
    return_code = 0;

cleanup:
    if (trace_installed) {
        PyEval_SetTrace(NULL, NULL);
    }
    amber_shell_python_trace_control = NULL;
    if (control != NULL) {
        AmberShellExecutionState state =
            amber_shell_execution_control_checkpoint(control);
        if (amber_shell_python_apply_control_state(result, state) != 0) {
            return_code = -1;
        }
    }
    Py_XDECREF(source);
    Py_XDECREF(input);
    Py_XDECREF(call_result);
    PyGILState_Release(gil_state);
    return return_code;
}

int amber_shell_python_execute(
    const char *resource_path,
    const char *app_path,
    const uint8_t *source_bytes,
    size_t source_length,
    const uint8_t *stdin_bytes,
    size_t stdin_length,
    AmberShellExecutionControl *control,
    AmberShellPythonBridgeResult *result) {
    if (result == NULL) {
        return -1;
    }
    memset(result, 0, sizeof(*result));

    if (stdin_length > AMBER_SHELL_PYTHON_MAX_STDIN_BYTES) {
        amber_shell_python_set_error(
            result,
            "AmberShell Python stdin cannot exceed 65536 UTF-8 bytes.",
            2);
        return -1;
    }
    if (source_length > 0 && source_bytes == NULL) {
        amber_shell_python_set_error(
            result,
            "AmberShell Python source is missing.",
            2);
        return -1;
    }
    if (stdin_length > 0 && stdin_bytes == NULL) {
        amber_shell_python_set_error(
            result,
            "AmberShell Python stdin is missing.",
            2);
        return -1;
    }

    pthread_mutex_lock(&amber_shell_python_mutex);

    if (amber_shell_python_initialize_locked(resource_path, app_path) != 0) {
        const char *message = amber_shell_python_initialization_error;
        if (message == NULL) {
            message = "Unable to initialize CPython.";
        }
        amber_shell_python_set_error(result, message, 74);
        pthread_mutex_unlock(&amber_shell_python_mutex);
        return -1;
    }

    int status = amber_shell_python_execute_locked(
        source_bytes,
        source_length,
        stdin_bytes,
        stdin_length,
        control,
        result);
    pthread_mutex_unlock(&amber_shell_python_mutex);
    return status;
}

void amber_shell_python_execution_result_dispose(
    AmberShellPythonBridgeResult *result) {
    if (result == NULL) {
        return;
    }
    free(result->stdout_bytes);
    free(result->stderr_bytes);
    free(result->error_message);
    memset(result, 0, sizeof(*result));
}
