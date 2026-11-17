// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZCodeMobileCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ZCodeMobileCore", targets: ["ZCodeMobileCore"]),
    ],
    targets: [
        .target(name: "ZCodeMobileCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ZCodeMobileCoreTests", dependencies: ["ZCodeMobileCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
