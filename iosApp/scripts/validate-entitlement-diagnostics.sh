#!/bin/sh
set -eu

entitlements_path="${1:?missing entitlements path}"
info_plist_path="${2:?missing Info.plist path}"
configured_key="${3:-AmberAgentConfiguredEntitlements}"

/usr/bin/python3 - "$entitlements_path" "$info_plist_path" "$configured_key" <<'PY'
import plistlib
import sys

entitlements_path, info_plist_path, configured_key = sys.argv[1], sys.argv[2], sys.argv[3]

with open(entitlements_path, "rb") as handle:
    entitlements = plistlib.load(handle)

with open(info_plist_path, "rb") as handle:
    info_plist = plistlib.load(handle)

configured = info_plist.get(configured_key)
if configured is None:
    print(f"{configured_key} is missing from Info.plist", file=sys.stderr)
    sys.exit(1)

if not isinstance(configured, list) or any(not isinstance(item, str) for item in configured):
    print(f"{configured_key} must be an array of strings", file=sys.stderr)
    sys.exit(1)

declared = sorted(entitlements.keys())
configured = sorted(configured)

if declared != configured:
    print(f"{configured_key} must match {entitlements_path} exactly.", file=sys.stderr)
    print(f"Declared in entitlements: {declared}", file=sys.stderr)
    print(f"Configured in Info.plist: {configured}", file=sys.stderr)
    sys.exit(1)
PY
