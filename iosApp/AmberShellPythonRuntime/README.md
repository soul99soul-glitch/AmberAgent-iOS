# AmberShell Python runtime

This directory is a stable-`iosApp`-only source boundary for the embedded
CPython bridge. The `iosAppExperimentalGPL` target must not include this
directory, the Python framework, or the Python processing build phase.

The pure Python application resources belong in the stable target's
`AmberShellPythonApp` resource directory. `Python.xcframework` is a local,
regeneratable build artifact and is ignored by Git.

The bridge accepts an optional `AmberShellExecutionControl` for each call.
Its monotonic deadline and cancellation state are checked from CPython's trace
callback while Python bytecode is executing. This interrupts pure-Python loops;
it cannot forcibly stop a blocking C extension or other native call. The
caller owns the control object and must keep it alive until the bridge call
returns.

## Prepare the pinned runtime

Run:

```bash
iosApp/scripts/prepare-ambershell-python.sh
```

The script uses only the official CPython 3.14.7 source archive:

```text
https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tar.xz
SHA-256: 3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81
```

When available, `/private/tmp/cpython-ios-3.14.7-cross-build/iOS/Python.xcframework`
is reused and copied into `iosApp/Python.xcframework`. Otherwise the script
downloads and verifies the source, then invokes CPython's official Apple iOS
build command to produce that artifact.

The stable target processes the standard library during its
`Process Python libraries` post-compile phase with CPython's `install_python`
helper. This phase runs after bundle resources are copied and before framework
embedding.

The stable app also bundles the tracked CPython 3.14.7 notice at
`Resources/Licenses/CPython-3.14.7.txt`. The ExperimentalGPL target does not
include this Python-specific resource.
