#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-Debug}"
action="${1:-build}"
case "$action" in
  build|test) ;;
  *) echo "Usage: $0 [build|test]" >&2; exit 2 ;;
esac
if [ "$(uname -m)" != arm64 ]; then
  echo "Amber Mac currently builds for Apple Silicon (arm64)." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required to generate AmberMac.xcodeproj." >&2
  exit 1
fi
cd "$project_dir"
xcodegen generate
xcodebuild -quiet -project AmberMac.xcodeproj -scheme AmberMac \
  -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$project_dir/build" \
  -parallel-testing-enabled NO "$action"
