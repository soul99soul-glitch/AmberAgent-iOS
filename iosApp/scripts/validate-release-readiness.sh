#!/bin/sh
set -eu

info_plist_path="${1:?missing Info.plist path}"
privacy_manifest_path="${2:?missing PrivacyInfo.xcprivacy path}"
project_yml_path="${3:?missing project.yml path}"

/usr/bin/python3 - "$info_plist_path" "$privacy_manifest_path" "$project_yml_path" <<'PY'
import plistlib
import sys

info_path, privacy_path, project_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(info_path, "rb") as handle:
    info = plistlib.load(handle)
with open(privacy_path, "rb") as handle:
    privacy = plistlib.load(handle)
with open(project_path, "r", encoding="utf-8") as handle:
    project = handle.read()

errors = []

background_modes = info.get("UIBackgroundModes", [])
if "audio" in background_modes:
    errors.append("stable release must not declare the audio background mode")
if "processing" not in background_modes:
    errors.append("BGContinuedProcessingTask requires the processing background mode")

ats = info.get("NSAppTransportSecurity", {})
if ats.get("NSAllowsArbitraryLoads") is True:
    errors.append("NSAllowsArbitraryLoads must remain disabled")
if ats.get("NSExceptionDomains"):
    errors.append("broad ATS exception domains are not allowed in the stable release plist")

if privacy.get("NSPrivacyTracking") is not False:
    errors.append("NSPrivacyTracking must be false")

declared = {
    item.get("NSPrivacyAccessedAPIType"): set(item.get("NSPrivacyAccessedAPITypeReasons", []))
    for item in privacy.get("NSPrivacyAccessedAPITypes", [])
}
required = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
}
for category, reasons in required.items():
    if not reasons.issubset(declared.get(category, set())):
        errors.append(f"privacy manifest is missing {category}: {sorted(reasons)}")

for bundle_id in (
    "app.amber.ios",
    "app.amber.ios.activity",
    "app.amber.ios.watchkitapp",
):
    if f"PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}" not in project:
        errors.append(f"stable target bundle identifier is missing: {bundle_id}")

for placeholder in ("YOUR_TEAM_ID", "YOUR_DOMAIN", "REPLACE_ME"):
    if placeholder in project:
        errors.append(f"unresolved release placeholder remains in project.yml: {placeholder}")

if errors:
    for error in errors:
        print(f"Release readiness: {error}", file=sys.stderr)
    sys.exit(1)
PY
