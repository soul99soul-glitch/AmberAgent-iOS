#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/amber-mac-runtime.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$test_dir/ModuleCache}"
mkdir -p "$test_dir/Sources/AmberMac" "$test_dir/Tests/AmberMacTests"

# Compile the same platform-independent Swift sources used by both Mac targets.
# KMP adapters are verified separately by the formal app's integration tests.
for source in "$project_dir"/AmberMac/Runtime/*.swift; do
  case "$(basename "$source")" in
    DesktopProvider.swift|DesktopConversationStorage.swift|DesktopLiveWorkspace.swift|DesktopKMPModelCatalog.swift|DesktopGeminiPrimitives.swift|DesktopSearchTransport.swift|DesktopAgentProvider.swift|DesktopEngineLedger.swift) continue ;;
  esac
  cp "$source" "$test_dir/Sources/AmberMac/"
done
cp "$project_dir/AmberMac/UI/DesktopMarkdownParser.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSCodexOAuthClient.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSImageGenerationModels.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSImageGenerationRepository.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/Chat/Media/ChatGeneratedImageURL.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSMcpClient.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSCredentialRedactor.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSWebDAVClient.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSSyncBackupError.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/Infrastructure/Networking/IOSPublicURLPolicy.swift" "$test_dir/Sources/AmberMac/"
cp "$project_dir/../iosApp/iosApp/IOSWebMountPublicDNS.swift" "$test_dir/Sources/AmberMac/"
for source in "$project_dir"/AmberMacTests/*.swift; do
  case "$(basename "$source")" in
    # Need the KMP Shared framework or the full app wiring; they run in the Xcode test target.
    KMPProviderIntegrationTests.swift|DesktopGrokOAuthTests.swift|LiveGatewayE2ETests.swift|DesktopSearchLiveProbeTests.swift|DesktopIOSBackupTests.swift) continue ;;
  esac
  cp "$source" "$test_dir/Tests/AmberMacTests/"
done
cp -R "$project_dir/AmberMacTests/Fixtures" "$test_dir/Tests/AmberMacTests/"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AmberMacRuntimeChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AmberMac"),
        .testTarget(name: "AmberMacTests", dependencies: ["AmberMac"], resources: [.process("Fixtures")])
    ]
)
SWIFT
swift test --package-path "$test_dir" "$@"
