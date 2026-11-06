#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."
phase="${1:?usage: run-structural-phase.sh PHASE}"
[[ "$phase" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
evidence="iosApp/build/StreamingPerfEvidence"
destination='platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0'
[[ -f "$evidence/replay-input-private.json" ]]
[[ ! -e "$evidence/$phase-e2e.xcresult" && ! -e "$evidence/$phase-fanout.xcresult" ]]
xcodegen generate --spec iosApp/project.yml > "$evidence/$phase-project.log" 2>&1
git rev-parse HEAD > "$evidence/$phase-head.txt"

# Separate test-host processes preserve the original e2e cold/warm-round boundary.
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination "$destination" -derivedDataPath iosApp/build/StreamingPerfBaseline \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSearchEndToEndReplayTests/testThreeConsecutiveCapturedRoundsThroughVisibleCompletion \
  -resultBundlePath "$evidence/$phase-e2e.xcresult" test > "$evidence/$phase-e2e.log" 2>&1
cp "$evidence/end-to-end-three-rounds.json" "$evidence/$phase-e2e-raw.json"
python3 iosApp/scripts/perf/summarize-e2e-replay.py "$evidence/$phase-e2e-raw.json" > "$evidence/$phase-e2e-summary.json"
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination "$destination" -derivedDataPath iosApp/build/StreamingPerfBaseline \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSearchCaptureReplayTests/testCapturedInvalidationFanout \
  -resultBundlePath "$evidence/$phase-fanout.xcresult" test-without-building > "$evidence/$phase-fanout.log" 2>&1
cp "$evidence/invalidation-fanout.json" "$evidence/$phase-fanout-raw.json"
python3 iosApp/scripts/perf/summarize-fanout.py "$evidence/$phase-fanout-raw.json" > "$evidence/$phase-fanout-summary.json"
