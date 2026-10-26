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
# Re-sign the finished app with a stable identity: ad hoc signatures change every build, so Keychain's
# 「始终允许」never sticks and macOS keeps asking for the login password. Override with AMBER_SIGN_IDENTITY.
if [ "$action" = build ]; then
  identity="${AMBER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED | grep '"Apple Development' | head -1 | awk '{print $2}')}"
  app="$project_dir/build/Build/Products/$configuration/Amber.app"
  if [ -n "$identity" ] && [ -d "$app" ]; then
    codesign --force --timestamp=none --sign "$identity" "$app/Contents/Frameworks/Shared.framework"
    codesign --force --timestamp=none --options runtime --entitlements "$project_dir/AmberMac/Amber.entitlements" --sign "$identity" "$app"
  fi
fi
