#!/bin/bash
set -euo pipefail
CONTROL_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$CONTROL_ROOT"
# Keep ring's C/assembly objects compatible with Amber's iOS deployment target,
# even when the currently selected SDK is a newer beta.
export IPHONEOS_DEPLOYMENT_TARGET=26.0

if [[ $# -gt 0 ]]; then
  CONTROL_TARGETS=("$@")
else
  CONTROL_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
fi

for CONTROL_TARGET in "${CONTROL_TARGETS[@]}"; do
  case "$CONTROL_TARGET" in
    aarch64-apple-ios|aarch64-apple-ios-sim|aarch64-apple-darwin) ;;
    *) printf 'Unsupported target: %s\n' "$CONTROL_TARGET" >&2; exit 2 ;;
  esac
  cargo build --locked --release --target "$CONTROL_TARGET" -p amber-iphone-control
  printf 'Library: %s/target/%s/release/libamber_iphone_control.a\n' "$CONTROL_ROOT" "$CONTROL_TARGET"
done
