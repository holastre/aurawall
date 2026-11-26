// swift-tools-version: 6.0
import Foundation
import PackageDescription

let cltTestingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPluginPath)
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginPath])]
    : []

let package = Package(
    name: "AuraWall",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AuraWallCore",
            targets: ["AuraWallCore"]
        ),
        .executable(
            name: "AuraWall",
            targets: ["AuraWall"]
        )
    ],
    targets: [
        .target(
            name: "AuraWallCore",
            path: "Sources/AuraWallCore"
        ),
        .executableTarget(
            name: "AuraWall",
            dependencies: ["AuraWallCore"],
            path: "Sources/AuraWall"
        ),
        .testTarget(
            name: "AuraWallCoreTests",
            dependencies: ["AuraWallCore"],
            path: "Tests/AuraWallCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        )
    ]
)
