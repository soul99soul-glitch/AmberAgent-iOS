// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "amber-gateway",
    // macOS 15: SecPKCS12Import(kSecImportToMemoryOnly) keeps the TLS identity out of the keychain.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "amber-gateway", targets: ["amber-gateway"]),
        // Linked by the Amber Mac app (macApp/project.yml), which embeds and manages the daemon.
        .library(name: "GatewayKit", targets: ["GatewayCore", "HookIngest", "SessionWatch", "GatewayTransport", "GatewayPush"]),
    ],
    targets: [
        .target(name: "GatewayCore"),
        .target(name: "HookIngest", dependencies: ["GatewayCore"]),
        .target(
            name: "SessionWatch",
            dependencies: ["GatewayCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .target(
            name: "GatewayTransport",
            dependencies: ["GatewayCore"],
            linkerSettings: [.linkedFramework("CoreImage"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "GatewayPush", dependencies: ["GatewayCore"]),
        .executableTarget(
            name: "amber-gateway",
            dependencies: ["GatewayCore", "HookIngest", "SessionWatch", "GatewayTransport", "GatewayPush"]
        ),
        .testTarget(
            name: "GatewayTests",
            dependencies: ["GatewayCore", "HookIngest", "SessionWatch", "GatewayTransport", "GatewayPush"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
