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

The interpreter remains process-global, but user jobs do not retain imported
allowlisted module families. The helper rejects writes and deletes through
module-derived attributes or subscripts, then restores or evicts allowlisted
modules on every result path. This is job-state hygiene, not a claim that the
helper is a security sandbox.

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

Existing repository artifacts and `/private/tmp` prebuilt XCFrameworks are
never trusted or reused. The script downloads (or reuses) only the pinned
source archive after verifying its SHA-256, extracts it into a fresh temporary
source tree, and invokes CPython's official Apple iOS build command. The
resulting XCFramework receives a complete content manifest plus the adjacent
`iosApp/Python.xcframework.receipt`; Stable Xcode builds validate both before
compiling or sourcing CPython's build utilities.

The stable target processes the standard library during its
`Process Python libraries` post-compile phase with CPython's `install_python`
helper. This phase runs after bundle resources are copied and before framework
embedding.

The stable app also bundles the tracked CPython 3.14.7 notice at
`Resources/Licenses/CPython-3.14.7.txt`. The ExperimentalGPL target does not
include this Python-specific resource.
