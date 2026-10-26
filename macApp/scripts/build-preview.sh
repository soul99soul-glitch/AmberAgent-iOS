#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
xcodegen generate
xcodebuild -quiet -project AmberMac.xcodeproj -scheme AmberMacPreview \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$project_dir/build" "$@" build
