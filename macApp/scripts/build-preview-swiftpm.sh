#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$project_dir/.." && pwd)"
preview_build_dir="$project_dir/build/swiftpm-preview"
math_package_path=""
if [ "${1:-}" = "--iosmath-path" ] && [ "$#" = 2 ]; then
  math_package_path="$(cd "$2" && pwd)"
elif [ "$#" != 0 ]; then
  echo "Usage: $0 [--iosmath-path /path/to/pinned/iosMath]" >&2
  exit 2
fi
export AMBER_PREVIEW_PROJECT="$project_dir"
export AMBER_PREVIEW_REPO="$repo_dir"
export AMBER_PREVIEW_BUILD="$preview_build_dir"
export AMBER_PREVIEW_MATH_PACKAGE="$math_package_path"
python3 - <<'PY'
import json, os, pathlib, shutil, subprocess
project = pathlib.Path(os.environ['AMBER_PREVIEW_PROJECT'])
repo = pathlib.Path(os.environ['AMBER_PREVIEW_REPO'])
build = pathlib.Path(os.environ['AMBER_PREVIEW_BUILD'])
pin = '066ba2f8353782a644889efe9ceb884ea844180b'
local = os.environ['AMBER_PREVIEW_MATH_PACKAGE']
if local:
    actual = subprocess.check_output(['git', '-C', local, 'rev-parse', 'HEAD'], text=True).strip()
    if actual != pin: raise SystemExit('iosMath checkout must match the production revision ' + pin)
    if subprocess.run(['git', '-C', local, 'diff', '--quiet', 'HEAD', '--']).returncode:
        raise SystemExit('iosMath checkout must contain the unmodified pinned production source')
    dependency = '.package(path: ' + json.dumps(local) + ')'
else:
    dependency = '.package(url: "https://github.com/maitbayev/iosMath", revision: "' + pin + '")'
sources = build/'Sources'/'AmberMacPreview'
if sources.exists(): shutil.rmtree(sources)
sources.mkdir(parents=True)
excluded = {'DesktopProvider.swift', 'DesktopAgentProvider.swift', 'DesktopConversationStorage.swift',
    'DesktopLiveWorkspace.swift', 'DesktopKMPModelCatalog.swift', 'DesktopGeminiPrimitives.swift',
    'DesktopSearchTransport.swift', 'DesktopEngineLedger.swift', 'AmberMacApp.swift'}
for folder in [project/'AmberMac'/'Runtime', project/'AmberMac'/'UI', project/'Preview']:
    for source in folder.glob('*.swift'):
        if source.name not in excluded: shutil.copy2(source, sources/source.name)
for name in ['IOSMcpClient.swift', 'IOSCredentialRedactor.swift', 'IOSWebDAVClient.swift', 'IOSSyncBackupError.swift',
    'IOSCodexOAuthClient.swift', 'IOSImageGenerationModels.swift', 'IOSImageGenerationRepository.swift',
    'Chat/Media/ChatGeneratedImageURL.swift', 'Infrastructure/Networking/IOSPublicURLPolicy.swift']:
    shutil.copy2(repo/'iosApp'/'iosApp'/name, sources/pathlib.Path(name).name)
(build/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AmberPreview", platforms: [.macOS(.v15)],
    products: [.executable(name: "AmberPreview", targets: ["AmberMacPreview"])],
    dependencies: [''' + dependency + '''], targets: [
        .executableTarget(name: "AmberMacPreview", dependencies: [.product(name: "iosMath", package: "iosMath")],
            swiftSettings: [.define("AMBER_MAC_PREVIEW")])])
''')
PY
export SWIFTPM_MODULECACHE_OVERRIDE="$preview_build_dir/ModuleCache"
swift build --package-path "$preview_build_dir" --disable-sandbox -j 2 \
  -Xswiftc -Xfrontend -Xswiftc -disable-sandbox
products_dir="$(swift build --package-path "$preview_build_dir" --show-bin-path --disable-sandbox)"
export AMBER_PREVIEW_PRODUCTS="$products_dir"
python3 - <<'PY'
import os, pathlib, plistlib, shutil
project = pathlib.Path(os.environ['AMBER_PREVIEW_PROJECT'])
build = pathlib.Path(os.environ['AMBER_PREVIEW_BUILD'])
products = pathlib.Path(os.environ['AMBER_PREVIEW_PRODUCTS'])
app = build/'AmberPreview.app'
if app.exists(): shutil.rmtree(app)
contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True)
(contents/'Resources').mkdir()
shutil.copy2(products/'AmberPreview', contents/'MacOS'/'AmberPreview')
bundles = list(products.glob('*.bundle'))
if not any(bundle.name == 'iosMath_iosMath.bundle' for bundle in bundles): raise SystemExit('Missing real iosMath font resource bundle')
for bundle in bundles: shutil.copytree(bundle, contents/'Resources'/bundle.name)
with (project/'Preview'/'Info.plist').open('rb') as file: info = plistlib.load(file)
info.update(CFBundleExecutable='AmberPreview', CFBundleIdentifier='app.amber.macos.preview', LSMinimumSystemVersion='15.0')
with (contents/'Info.plist').open('wb') as file: plistlib.dump(info, file)
PY
xcrun actool "$project_dir/AmberMac/Resources/Assets.xcassets" \
  --compile "$preview_build_dir/AmberPreview.app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$preview_build_dir/assets-info.plist" >/dev/null
python3 - <<'PY'
import os, pathlib, plistlib
build = pathlib.Path(os.environ['AMBER_PREVIEW_BUILD'])
info_path = build/'AmberPreview.app'/'Contents'/'Info.plist'
with info_path.open('rb') as file: info = plistlib.load(file)
with (build/'assets-info.plist').open('rb') as file: info.update(plistlib.load(file))
with info_path.open('wb') as file: plistlib.dump(info, file)
PY
codesign --force --sign - --entitlements "$project_dir/Preview/AmberPreview.entitlements" "$preview_build_dir/AmberPreview.app"
codesign --verify --deep --strict "$preview_build_dir/AmberPreview.app"
echo "$preview_build_dir/AmberPreview.app"
