#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="3.14.7"
PYTHON_SHA256="3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81"
PYTHON_SOURCE_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_XCFRAMEWORK="${IOS_APP_DIR}/Python.xcframework"
PREBUILT_XCFRAMEWORK="/private/tmp/cpython-ios-${PYTHON_VERSION}-cross-build/iOS/Python.xcframework"
CPYTHON_ROOT="/private/tmp/cpython-ios-${PYTHON_VERSION}"
CACHE_ROOT="/private/tmp/cpython-ios-${PYTHON_VERSION}-cache"
SOURCE_ARCHIVE="${CPYTHON_ROOT}/Python-${PYTHON_VERSION}.tar.xz"
SOURCE_DIR="${CPYTHON_ROOT}/Python-${PYTHON_VERSION}"
SOURCE_BUILD_ROOT="${SOURCE_DIR}/cross-build"

if [ -d "${PYTHON_XCFRAMEWORK}" ]; then
  echo "Using existing ${PYTHON_XCFRAMEWORK}"
  exit 0
fi

if [ -d "${PREBUILT_XCFRAMEWORK}" ]; then
  echo "Copying prebuilt ${PREBUILT_XCFRAMEWORK}"
  ditto "${PREBUILT_XCFRAMEWORK}" "${PYTHON_XCFRAMEWORK}"
  exit 0
fi

mkdir -p "${CPYTHON_ROOT}"
if [ ! -f "${SOURCE_ARCHIVE}" ]; then
  curl --fail --location --retry 2 --retry-delay 1 \
    --output "${SOURCE_ARCHIVE}.partial" \
    "${PYTHON_SOURCE_URL}"
  mv "${SOURCE_ARCHIVE}.partial" "${SOURCE_ARCHIVE}"
fi

printf '%s  %s\n' "${PYTHON_SHA256}" "${SOURCE_ARCHIVE}" | shasum --algorithm 256 --check

if [ ! -d "${SOURCE_DIR}" ]; then
  tar --extract --xz --file "${SOURCE_ARCHIVE}" --directory "${CPYTHON_ROOT}"
fi

python3_bin="$(command -v python3 || true)"
if [ -z "${python3_bin}" ]; then
  echo "python3 is required to run CPython's official Apple build script." >&2
  exit 1
fi

echo "Building CPython ${PYTHON_VERSION} iOS XCframework from the verified official source."
(
  cd "${SOURCE_DIR}"
  PATH="${SOURCE_DIR}/Apple/iOS/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
    "${python3_bin}" Apple build iOS \
      --cross-build-dir "${SOURCE_BUILD_ROOT}" \
      --cache-dir "${CACHE_ROOT}" \
      --clean
)

BUILT_XCFRAMEWORK="${SOURCE_BUILD_ROOT}/iOS/Python.xcframework"
if [ ! -d "${BUILT_XCFRAMEWORK}" ]; then
  echo "CPython build completed without ${BUILT_XCFRAMEWORK}." >&2
  exit 1
fi

ditto "${BUILT_XCFRAMEWORK}" "${PYTHON_XCFRAMEWORK}"
echo "Prepared ${PYTHON_XCFRAMEWORK}"
