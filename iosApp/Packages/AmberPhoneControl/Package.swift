// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AmberPhoneControl",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "AmberPhoneControl", targets: ["AmberPhoneControl"])],
    targets: [
        .target(name: "AmberPhoneControl"),
        .testTarget(name: "AmberPhoneControlTests", dependencies: ["AmberPhoneControl"]),
    ]
)
