#!/usr/bin/env bash
set -euo pipefail

# The manifest is kept inside the generated XCFramework so it can describe the
# complete tree. The adjacent receipt is the trust boundary used by Xcode: a
# copied or modified XCFramework no longer matches the receipt and is rejected.
PYTHON_VERSION="3.14.7"
PYTHON_SHA256="3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81"
MANIFEST_VERSION="amberagent-cpython-manifest-v1"
MANIFEST_NAME=".amberagent-cpython-${PYTHON_VERSION}.manifest"
RECEIPT_VERSION="amberagent-cpython-receipt-v1"

fail() {
  echo "AmberShell Python artifact validation failed: $*" >&2
  exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  fail "usage: $0 /path/to/Python.xcframework [receipt-path]"
fi

ARTIFACT_ROOT="$1"
if [ ! -d "$ARTIFACT_ROOT" ] || [ -L "$ARTIFACT_ROOT" ]; then
  fail "XCFramework must be a real directory: ${ARTIFACT_ROOT}"
fi

if [ "$#" -eq 2 ]; then
  RECEIPT_PATH="$2"
else
  RECEIPT_PATH="${ARTIFACT_ROOT}.receipt"
fi
if [ ! -f "$RECEIPT_PATH" ] || [ -L "$RECEIPT_PATH" ]; then
  fail "missing generated provenance receipt (${RECEIPT_PATH})"
fi

MANIFEST_PATH="${ARTIFACT_ROOT}/${MANIFEST_NAME}"
if [ ! -f "$MANIFEST_PATH" ] || [ -L "$MANIFEST_PATH" ]; then
  fail "missing generated provenance manifest (${MANIFEST_NAME})"
fi

if [ ! -f "${ARTIFACT_ROOT}/Info.plist" ] || [ -L "${ARTIFACT_ROOT}/Info.plist" ]; then
  fail "missing XCFramework Info.plist"
fi
if ! plutil -lint "${ARTIFACT_ROOT}/Info.plist" >/dev/null 2>&1; then
  fail "invalid XCFramework Info.plist"
fi

manifest_value() {
  local key="$1"
  local value
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); count++ } END { if (count != 1) exit 1 }' "$MANIFEST_PATH")" \
    || fail "manifest must contain exactly one ${key} entry"
  printf '%s' "$value"
}

receipt_value() {
  local key="$1"
  local value
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); count++ } END { if (count != 1) exit 1 }' "$RECEIPT_PATH")" \
    || fail "receipt must contain exactly one ${key} entry"
  printf '%s' "$value"
}

if [ "$(receipt_value receipt_version)" != "$RECEIPT_VERSION" ]; then
  fail "unsupported provenance receipt version"
fi
if [ "$(receipt_value python_version)" != "$PYTHON_VERSION" ]; then
  fail "receipt contains an unexpected CPython version"
fi
if [ "$(receipt_value source_sha256)" != "$PYTHON_SHA256" ]; then
  fail "receipt source archive hash does not match the pinned CPython source"
fi

if ! awk -F= '
  $0 ~ /^(receipt_version|python_version|source_sha256|manifest_sha256|content_sha256)=/ { next }
  { invalid = 1 }
  END { exit invalid ? 1 : 0 }
' "$RECEIPT_PATH"; then
  fail "provenance receipt contains an unknown entry"
fi

if [ "$(manifest_value manifest_version)" != "$MANIFEST_VERSION" ]; then
  fail "unsupported manifest version"
fi
if [ "$(manifest_value python_version)" != "$PYTHON_VERSION" ]; then
  fail "unexpected CPython version"
fi
if [ "$(manifest_value source_sha256)" != "$PYTHON_SHA256" ]; then
  fail "source archive hash does not match the pinned CPython source"
fi

if ! awk -F '\t' '
  $0 ~ /^(manifest_version|python_version|source_sha256|slice_names|content_sha256)=/ { next }
  $1 == "file" || $1 == "symlink" { next }
  { invalid = 1 }
  END { exit invalid ? 1 : 0 }
' "$MANIFEST_PATH"; then
  fail "manifest contains an unknown entry"
fi

slice_names="$(manifest_value slice_names)"
case ",${slice_names}," in
  *,ios-arm64,* ) ;;
  * ) fail "device arm64 slice is missing from manifest" ;;
esac
case ",${slice_names}," in
  *,ios-arm64_x86_64-simulator,*|*,ios-arm64-simulator,* ) ;;
  * ) fail "arm64 simulator slice is missing from manifest" ;;
esac

if [ ! -d "${ARTIFACT_ROOT}/ios-arm64/Python.framework" ]; then
  fail "missing ios-arm64/Python.framework"
fi

SIMULATOR_SLICE=""
for candidate in ios-arm64_x86_64-simulator ios-arm64-simulator; do
  if [ -d "${ARTIFACT_ROOT}/${candidate}/Python.framework" ]; then
    SIMULATOR_SLICE="$candidate"
    break
  fi
done
if [ -z "$SIMULATOR_SLICE" ]; then
  fail "missing supported arm64 simulator Python.framework"
fi

validate_framework() {
  local slice="$1"
  local framework="${ARTIFACT_ROOT}/${slice}/Python.framework"
  local binary="${framework}/Python"

  if [ ! -f "$binary" ] || [ -L "$binary" ]; then
    fail "${slice}/Python.framework/Python is missing or is a symlink"
  fi
  if [ ! -f "${framework}/Headers/Python.h" ]; then
    fail "${slice}/Python.framework/Headers/Python.h is missing"
  fi
  if ! plutil -lint "${framework}/Info.plist" >/dev/null 2>&1; then
    fail "invalid ${slice}/Python.framework/Info.plist"
  fi

  local lipo_info
  lipo_info="$(lipo -info "$binary" 2>/dev/null)" \
    || fail "unable to inspect ${slice}/Python.framework/Python"
  case "$lipo_info" in
    *arm64*) ;;
    *) fail "${slice}/Python.framework/Python does not contain arm64" ;;
  esac
  if [ "$slice" = "$SIMULATOR_SLICE" ]; then
    case "$lipo_info" in
      *x86_64*|*arm64*) ;;
      *) fail "simulator Python binary has no supported architecture" ;;
    esac
  fi
}

validate_framework ios-arm64
validate_framework "$SIMULATOR_SLICE"

# Relative symlinks are allowed by CPython's package layout, but a symlink may
# not escape the XCFramework root. Resolve the target instead of rejecting all
# '..' components; framework layouts may legitimately use parent-relative links.
ARTIFACT_REAL_ROOT="$(realpath "$ARTIFACT_ROOT")" \
  || fail "unable to resolve XCFramework root"
while IFS= read -r -d '' link_path; do
  link_target="$(readlink "$link_path")"
  resolved_link="$(realpath "$link_path" 2>/dev/null)" \
    || fail "XCFramework contains a broken symlink: ${link_path#"${ARTIFACT_ROOT}/"}"
  case "$resolved_link" in
    "${ARTIFACT_REAL_ROOT}"/*) ;;
    *) fail "XCFramework symlink escapes its root: ${link_path#"${ARTIFACT_ROOT}/"} -> ${link_target}" ;;
  esac
done < <(find "$ARTIFACT_ROOT" -type l -print0)

manifest_body="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-manifest.XXXXXX")"
actual_body="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-body.XXXXXX")"
file_hashes="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-file-hashes.XXXXXX")"
trap 'rm -f "$manifest_body" "$actual_body" "$file_hashes"' EXIT

if ! find "$ARTIFACT_ROOT" -type f ! -path "$MANIFEST_PATH" -print0 |
  xargs -0 shasum -a 256 > "$file_hashes"; then
  fail "unable to hash XCFramework contents"
fi

# Build a canonical inventory. Sorting makes the digest independent of find's
# traversal order; the manifest path itself is excluded to avoid a hash cycle.
{
  while IFS= read -r hash_line; do
    file_hash="${hash_line%% *}"
    file_path="${hash_line#* }"
    file_path="${file_path# }"
    rel_path="${file_path#"${ARTIFACT_ROOT}/"}"
    printf 'file\t%s\t%s\n' "$file_hash" "$rel_path"
  done < "$file_hashes"

  while IFS= read -r -d '' link_path; do
    rel_path="${link_path#"${ARTIFACT_ROOT}/"}"
    if [ "$rel_path" = "$MANIFEST_NAME" ]; then
      continue
    fi
    printf 'symlink\t%s\t%s\n' "$(readlink "$link_path")" "$rel_path"
  done < <(find "$ARTIFACT_ROOT" -type l -print0)
} | LC_ALL=C sort > "$actual_body"

expected_body_hash="$(manifest_value content_sha256)"
actual_body_hash="$(shasum -a 256 "$actual_body" | awk '{ print $1 }')"
if [ "$expected_body_hash" != "$actual_body_hash" ]; then
  fail "XCFramework content digest does not match its provenance manifest"
fi

if [ "$(receipt_value content_sha256)" != "$expected_body_hash" ]; then
  fail "provenance receipt content digest does not match the XCFramework manifest"
fi
actual_manifest_hash="$(shasum -a 256 "$MANIFEST_PATH" | awk '{ print $1 }')"
if [ "$(receipt_value manifest_sha256)" != "$actual_manifest_hash" ]; then
  fail "XCFramework manifest does not match its adjacent provenance receipt"
fi

awk -F '\t' '$1 == "file" || $1 == "symlink" { print }' "$MANIFEST_PATH" | LC_ALL=C sort > "$manifest_body"
if ! cmp -s "$actual_body" "$manifest_body"; then
  fail "XCFramework file inventory differs from its provenance manifest"
fi

echo "Verified CPython ${PYTHON_VERSION} iOS XCFramework (${slice_names})."
