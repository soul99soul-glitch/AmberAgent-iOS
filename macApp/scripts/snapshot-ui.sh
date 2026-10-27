#!/bin/bash
# Offscreen native snapshots of the real DesktopWorkspaceView with the UI fixture (Preview source set, no KMP).
# Usage: macApp/scripts/snapshot-ui.sh <out-dir>
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?out dir}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
work=/tmp/amber-ui-snapshot
mkdir -p "$work/Sources/AmberSnapshot"
rm -f "$work/Sources/AmberSnapshot/"*.swift
exclude=" AmberMacApp.swift DesktopProvider.swift DesktopAgentProvider.swift DesktopConversationStorage.swift DesktopLiveWorkspace.swift DesktopKMPModelCatalog.swift DesktopGeminiPrimitives.swift DesktopSearchTransport.swift DesktopEngineLedger.swift "
find "$project_dir/AmberMac" -name '*.swift' | while read -r f; do
  case "$exclude" in *" $(basename "$f") "*) continue;; esac
  cp "$f" "$work/Sources/AmberSnapshot/"
done
# Shared iOS sources the Preview target compiles (keep in sync with project.yml AmberMacPreview).
for f in IOSCodexOAuthClient.swift IOSImageGenerationModels.swift IOSImageGenerationRepository.swift Chat/Media/ChatGeneratedImageURL.swift \
  IOSMcpClient.swift IOSCredentialRedactor.swift IOSWebDAVClient.swift IOSSyncBackupError.swift Infrastructure/Networking/IOSPublicURLPolicy.swift IOSWebMountPublicDNS.swift; do
  cp "$project_dir/../iosApp/iosApp/$f" "$work/Sources/AmberSnapshot/"
done
cp "$project_dir/scripts/snapshot/SnapshotMain.swift" "$work/Sources/AmberSnapshot/"
cp "$project_dir/Preview/PreviewSettingsView.swift" "$work/Sources/AmberSnapshot/"
iosmath="$project_dir/build/SourcePackages/checkouts/iosMath"
cat > "$work/Package.swift" <<PKG
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AmberSnapshot", platforms: [.macOS(.v15)],
  dependencies: [.package(path: "$iosmath"), .package(path: "$project_dir/../gateway")],
  targets: [.executableTarget(name: "AmberSnapshot", dependencies: [.product(name: "iosMath", package: "iosMath"), .product(name: "GatewayKit", package: "gateway")],
    resources: [], swiftSettings: [.define("AMBER_MAC_PREVIEW"), .define("DEBUG")])])
PKG
cd "$work"
SWIFTPM_MODULECACHE_OVERRIDE="$work/ModuleCache" CLANG_MODULE_CACHE_PATH="$work/ClangModuleCache" \
  swift build --disable-sandbox -j 4 -Xswiftc -Xfrontend -Xswiftc -disable-sandbox > "$work/build.log" 2>&1 || { grep -E "error:" "$work/build.log" | sort -u | head -20; exit 1; }
AMBER_SNAPSHOT_OUT="$out" "$work/.build/debug/AmberSnapshot"
