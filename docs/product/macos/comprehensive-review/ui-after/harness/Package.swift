// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AmberOffscreenReview", platforms: [.macOS(.v15)], dependencies: [.package(path: "/Users/mi/Downloads/AI/AmberAgent/ios/iosApp/build/ExperimentalDeviceBuild/SourcePackages/checkouts/iosMath")], targets: [.executableTarget(name:"AmberOffscreenReview",dependencies:[.product(name:"iosMath",package:"iosMath")])])
