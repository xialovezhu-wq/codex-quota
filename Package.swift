// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexQuota",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexQuotaCore", targets: ["CodexQuotaCore"]),
        .executable(name: "CodexQuotaApp", targets: ["CodexQuotaApp"]),
        .executable(name: "CodexQuotaTests", targets: ["CodexQuotaTests"])
    ],
    targets: [
        .target(
            name: "CodexQuotaCore"
        ),
        .executableTarget(
            name: "CodexQuotaApp",
            dependencies: ["CodexQuotaCore"]
        ),
        .executableTarget(
            name: "CodexQuotaTests",
            dependencies: ["CodexQuotaCore"],
            path: "Tests/CodexQuotaTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
