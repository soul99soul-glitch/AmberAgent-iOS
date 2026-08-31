#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="3.14.7"
PYTHON_SHA256="3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81"
PYTHON_SOURCE_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
MANIFEST_NAME=".amberagent-cpython-${PYTHON_VERSION}.manifest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_XCFRAMEWORK="${IOS_APP_DIR}/Python.xcframework"
PYTHON_RECEIPT="${IOS_APP_DIR}/Python.xcframework.receipt"
CPYTHON_ROOT="/private/tmp/cpython-ios-${PYTHON_VERSION}"
SOURCE_ARCHIVE="${CPYTHON_ROOT}/Python-${PYTHON_VERSION}.tar.xz"
VALIDATOR="${SCRIPT_DIR}/validate-ambershell-python.sh"

fail() {
  echo "AmberShell Python preparation failed: $*" >&2
  exit 1
}

if [ ! -x "$VALIDATOR" ]; then
  fail "missing executable artifact validator: ${VALIDATOR}"
fi

declare -a CLEANUP_DIRS=()
cleanup() {
  local directory
  [ "${#CLEANUP_DIRS[@]}" -gt 0 ] || return 0
  for directory in "${CLEANUP_DIRS[@]}"; do
    [ -n "$directory" ] && rm -rf "$directory"
  done
}
trap cleanup EXIT

verify_source_archive() {
  [ -f "$SOURCE_ARCHIVE" ] || return 1
  [ ! -L "$SOURCE_ARCHIVE" ] || fail "source archive must not be a symlink"
  printf '%s  %s\n' "$PYTHON_SHA256" "$SOURCE_ARCHIVE" |
    shasum --algorithm 256 --check >/dev/null
}

collect_manifest_body() {
  local root="$1"
  local file_path rel_path file_hash link_path hash_line hash_output

  hash_output="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-file-hashes.XXXXXX")"
  CLEANUP_DIRS+=("$hash_output")
  if ! find "$root" -type f ! -path "${root}/${MANIFEST_NAME}" -print0 |
    xargs -0 shasum --algorithm 256 > "$hash_output"; then
    fail "unable to hash fresh CPython artifact"
  fi

  while IFS= read -r hash_line; do
    file_hash="${hash_line%% *}"
    file_path="${hash_line#* }"
    file_path="${file_path# }"
    rel_path="${file_path#"${root}/"}"
    printf 'file\t%s\t%s\n' "$file_hash" "$rel_path"
  done < "$hash_output"

  while IFS= read -r -d '' link_path; do
    rel_path="${link_path#"${root}/"}"
    [ "$rel_path" != "$MANIFEST_NAME" ] || continue
    printf 'symlink\t%s\t%s\n' "$(readlink "$link_path")" "$rel_path"
  done < <(find "$root" -type l -print0)
}

slice_names_for() {
  local root="$1"
  local candidate names=""
  for candidate in ios-arm64 ios-arm64_x86_64-simulator ios-arm64-simulator; do
    if [ -d "${root}/${candidate}" ]; then
      if [ -n "$names" ]; then
        names+=","
      fi
      names+="$candidate"
    fi
  done
  printf '%s' "$names"
}

write_manifest() {
  local root="$1"
  local body manifest_tmp body_hash slice_names
  body="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-manifest-body.XXXXXX")"
  CLEANUP_DIRS+=("$body")

  collect_manifest_body "$root" | LC_ALL=C sort > "$body"
  body_hash="$(shasum --algorithm 256 "$body" | awk '{ print $1 }')"
  slice_names="$(slice_names_for "$root")"
  [ -n "$slice_names" ] || fail "fresh CPython build has no iOS slices"

  manifest_tmp="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-manifest.XXXXXX")"
  CLEANUP_DIRS+=("$manifest_tmp")
  {
    printf 'manifest_version=amberagent-cpython-manifest-v1\n'
    printf 'python_version=%s\n' "$PYTHON_VERSION"
    printf 'source_sha256=%s\n' "$PYTHON_SHA256"
    printf 'slice_names=%s\n' "$slice_names"
    printf 'content_sha256=%s\n' "$body_hash"
    cat "$body"
  } > "$manifest_tmp"

  if [ -L "${root}/${MANIFEST_NAME}" ]; then
    fail "fresh CPython build contains a manifest symlink"
  fi
  rm -f "${root}/${MANIFEST_NAME}"
  mv "$manifest_tmp" "${root}/${MANIFEST_NAME}"
}

write_receipt() {
  local artifact_root="$1"
  local receipt_path="$2"
  local manifest_hash content_hash receipt_tmp

  manifest_hash="$(shasum --algorithm 256 "${artifact_root}/${MANIFEST_NAME}" | awk '{ print $1 }')"
  content_hash="$(awk -F= '$1 == "content_sha256" { print substr($0, index($0, "=") + 1); count++ } END { if (count != 1) exit 1 }' "${artifact_root}/${MANIFEST_NAME}")" \
    || fail "generated CPython manifest has no content digest"
  receipt_tmp="$(mktemp "${TMPDIR:-/tmp}/ambershell-python-receipt.XXXXXX")"
  CLEANUP_DIRS+=("$receipt_tmp")
  {
    printf 'receipt_version=amberagent-cpython-receipt-v1\n'
    printf 'python_version=%s\n' "$PYTHON_VERSION"
    printf 'source_sha256=%s\n' "$PYTHON_SHA256"
    printf 'manifest_sha256=%s\n' "$manifest_hash"
    printf 'content_sha256=%s\n' "$content_hash"
  } > "$receipt_tmp"
  mv "$receipt_tmp" "$receipt_path"
}

install_verified_artifact() {
  local source_root="$1"
  local staging_parent staging_root staging_receipt

  staging_parent="$(mktemp -d "${IOS_APP_DIR}/.ambershell-python-staging.XXXXXX")"
  staging_root="${staging_parent}/Python.xcframework"
  staging_receipt="${staging_parent}/Python.xcframework.receipt"
  CLEANUP_DIRS+=("$staging_parent")
  ditto "$source_root" "$staging_root"

  write_manifest "$staging_root"
  write_receipt "$staging_root" "$staging_receipt"
  "$VALIDATOR" "$staging_root" "$staging_receipt"

  # Do not expose an old artifact while a new one is being built. The target
  # is a generated, Git-ignored artifact and can always be regenerated from
  # the pinned source archive.
  if [ -e "$PYTHON_XCFRAMEWORK" ] || [ -L "$PYTHON_XCFRAMEWORK" ]; then
    rm -rf "$PYTHON_XCFRAMEWORK"
  fi
  if [ -e "$PYTHON_RECEIPT" ] || [ -L "$PYTHON_RECEIPT" ]; then
    rm -f "$PYTHON_RECEIPT"
  fi
  mv "$staging_root" "$PYTHON_XCFRAMEWORK"
  mv "$staging_receipt" "$PYTHON_RECEIPT"
  echo "Prepared verified ${PYTHON_XCFRAMEWORK}"
}

# Existing artifacts and the historical /private/tmp prebuilt cache are never
# reused. They remain in place for inspection while this script rebuilds from
# a fresh extraction of the verified official source archive.
if [ -e "$PYTHON_XCFRAMEWORK" ] || [ -L "$PYTHON_XCFRAMEWORK" ]; then
  echo "Existing ${PYTHON_XCFRAMEWORK} will be replaced after a clean CPython rebuild." >&2
fi

mkdir -p "$CPYTHON_ROOT"
if [ ! -f "$SOURCE_ARCHIVE" ]; then
  curl --fail --location --retry 2 --retry-delay 1 \
    --output "${SOURCE_ARCHIVE}.partial" \
    "$PYTHON_SOURCE_URL"
  mv "${SOURCE_ARCHIVE}.partial" "$SOURCE_ARCHIVE"
fi
verify_source_archive || fail "source archive SHA-256 does not match the pinned CPython release"

# Always extract into a new directory. Never reuse a source tree that may have
# been edited after the archive was verified; the archive is the provenance
# root for every rebuilt framework.
source_staging="$(mktemp -d "${CPYTHON_ROOT}/source.XXXXXX")"
dependency_cache="$(mktemp -d "${CPYTHON_ROOT}/dependency-cache.XXXXXX")"
CLEANUP_DIRS+=("$source_staging" "$dependency_cache")
tar --extract --xz --file "$SOURCE_ARCHIVE" --directory "$source_staging"
SOURCE_DIR="${source_staging}/Python-${PYTHON_VERSION}"
[ -d "$SOURCE_DIR" ] || fail "source archive did not contain Python-${PYTHON_VERSION}"
# CPython's official Apple packager resolves the final archive relative to the
# source tree. Keep the otherwise-fresh build root inside the fresh extraction
# so its packaging phase can complete without weakening isolation.
SOURCE_BUILD_ROOT="${SOURCE_DIR}/cross-build"

build_path="${SOURCE_DIR}/Apple/iOS/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"
python3_bin=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  candidate_path="$(command -v "$candidate" || true)"
  if [ -n "$candidate_path" ] && [ -x "$candidate_path" ] &&
    "$candidate_path" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
    python3_bin="$candidate_path"
    break
  fi
done
if [ -z "$python3_bin" ]; then
  fail "Python 3.10 or newer is required to run CPython's official Apple build script"
fi

echo "Building CPython ${PYTHON_VERSION} iOS XCframework from the verified official source."
(
  cd "$SOURCE_DIR"
  PATH="$build_path" "$python3_bin" Apple build iOS \
    --cross-build-dir "$SOURCE_BUILD_ROOT" \
    --cache-dir "$dependency_cache" \
    --clean
)

BUILT_XCFRAMEWORK="${SOURCE_BUILD_ROOT}/iOS/Python.xcframework"
[ -d "$BUILT_XCFRAMEWORK" ] || fail "CPython build completed without ${BUILT_XCFRAMEWORK}"
install_verified_artifact "$BUILT_XCFRAMEWORK"
