#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DESTINATION_ID="${AMBER_IOS_DESTINATION_ID:-00008150-000A594E0AF8401C}"
DEVICECTL_ID="${AMBER_IOS_DEVICECTL_ID:-${DESTINATION_ID}}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-TY4JTL3V2M}"
DERIVED_DATA_PATH="${AMBER_IOS_DERIVED_DATA_PATH:-build/ExperimentalDeviceBuild}"
SCHEME="iosAppExperimentalGPL"
BUNDLE_ID="${AMBER_IOS_BUNDLE_ID:-app.amber.ios}"
URL_SCHEME="${AMBER_IOS_URL_SCHEME:-amber}"
APP_BUNDLE_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug-iphoneos/${SCHEME}.app"
BUILD_LOG="${DERIVED_DATA_PATH}/experimental-gpl-device-build.log"

cd "${IOS_APP_DIR}"
mkdir -p "${DERIVED_DATA_PATH}"
xcodegen generate

echo "Building ${SCHEME} for device ${DESTINATION_ID}..."
set +e
xcodebuild -project AmberAgent.xcodeproj -scheme "${SCHEME}" \
  -destination "platform=iOS,id=${DESTINATION_ID}" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" CODE_SIGN_STYLE=Automatic \
  AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER="${BUNDLE_ID}" AGENT_ACTIVITY_URL_SCHEME="${URL_SCHEME}" \
  -skipMacroValidation -skipPackagePluginValidation \
  -derivedDataPath "${DERIVED_DATA_PATH}" build 2>&1 | tee "${BUILD_LOG}"
build_status=${PIPESTATUS[0]}
set -e

if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "${BUILD_LOG}"; then
  echo "ExperimentalGPL device build did not report ** BUILD SUCCEEDED **. See ${IOS_APP_DIR}/${BUILD_LOG}" >&2
  exit "${build_status:-1}"
fi

if [ ! -d "${APP_BUNDLE_PATH}" ]; then
  echo "Built app not found at ${IOS_APP_DIR}/${APP_BUNDLE_PATH}" >&2
  exit 1
fi

actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_BUNDLE_PATH}/Info.plist")
if [ "${actual_bundle_id}" != "${BUNDLE_ID}" ]; then
  echo "Built bundle identifier ${actual_bundle_id} does not match installation target ${BUNDLE_ID}" >&2
  exit 1
fi

echo "Installing ${APP_BUNDLE_PATH} to device ${DEVICECTL_ID}..."
xcrun devicectl device install app --device "${DEVICECTL_ID}" "${APP_BUNDLE_PATH}"

echo "Launching ${BUNDLE_ID} with --terminate-existing..."
xcrun devicectl device process launch --device "${DEVICECTL_ID}" --terminate-existing "${BUNDLE_ID}"

echo "Installed AmberAgent app record:"
xcrun devicectl device info apps --device "${DEVICECTL_ID}" --bundle-id "${BUNDLE_ID}" --columns '*'
