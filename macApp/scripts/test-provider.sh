#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/amber-mac-provider.XXXXXX")"
server_pid=''
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture_dir"
}
trap cleanup EXIT INT TERM
python3 "$project_dir/scripts/mock-provider.py" --ready-file "$fixture_dir/port" &
server_pid=$!
for _ in {1..100}; do
  if [ -s "$fixture_dir/port" ]; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo 'Local provider fixture failed to start.' >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$fixture_dir/port" ]; then
  echo 'Local provider fixture did not publish its port.' >&2
  exit 1
fi
fixture_port="$(cat "$fixture_dir/port")"
cd "$project_dir"
xcodegen generate
xcodebuild -quiet -project AmberMac.xcodeproj -scheme AmberMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$project_dir/build" -parallel-testing-enabled NO \
  "AMBER_MAC_PROVIDER_TEST_URL=http://127.0.0.1:$fixture_port" \
  "AMBER_MAC_PERFORMANCE_BENCHMARK=${AMBER_MAC_PERFORMANCE_BENCHMARK:-}" \
  "AMBER_MAC_GATEWAY_LIVE=${AMBER_MAC_GATEWAY_LIVE:-}" \
  -only-testing:AmberMacTests/KMPProviderIntegrationTests test
