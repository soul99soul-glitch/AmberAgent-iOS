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
if [ "$action" = test ]; then
  # The embedded gateway keeps its own SwiftPM suite (built binary, real TLS/UDS round trips).
  swift test --package-path "$project_dir/../gateway" --scratch-path "$project_dir/build/gateway"
fi
xcodebuild -quiet -project AmberMac.xcodeproj -scheme AmberMac \
  -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$project_dir/build" \
  -parallel-testing-enabled NO "$action"
# Re-sign the finished app with a stable identity: ad hoc signatures change every build, so Keychain's
# 「始终允许」never sticks and macOS keeps asking for the login password. Override with AMBER_SIGN_IDENTITY.
if [ "$action" = build ]; then
  # AMBER_DISTRIBUTION=1 signs with Developer ID and a secure timestamp, as notarization requires.
  kind='"Apple Development'; timestamp=--timestamp=none
  if [ "${AMBER_DISTRIBUTION:-0}" = 1 ]; then
    kind='"Developer ID Application'; timestamp=--timestamp
    # The Developer ID key lives in its own keychain (no access prompt for codesign); unlock it if present.
    signing_keychain="$HOME/Library/Keychains/amber-signing.keychain-db"
    if [ -f "$signing_keychain" ]; then
      security unlock-keychain -p "$(security find-generic-password -a amber-signing -s amber-signing-keychain -w)" "$signing_keychain"
    fi
  fi
  identity="${AMBER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED | grep "$kind" | head -1 | awk '{print $2}')}"
  app="$project_dir/build/Build/Products/$configuration/Amber.app"
  if [ "${AMBER_DISTRIBUTION:-0}" = 1 ] && [ -z "$identity" ]; then
    echo "No Developer ID Application identity in the keychain." >&2
    exit 1
  fi
  if [ -n "$identity" ] && [ -d "$app" ]; then
    codesign --force $timestamp --options runtime --sign "$identity" "$app/Contents/Frameworks/Shared.framework"
    # Embedded gateway daemon: SMAppService requires it to share the app's signing team.
    codesign --force $timestamp --options runtime --identifier app.amber.macos.gateway --sign "$identity" "$app/Contents/MacOS/amber-gateway"
    codesign --force $timestamp --options runtime --entitlements "$project_dir/AmberMac/Amber.entitlements" --sign "$identity" "$app"
  fi
fi
