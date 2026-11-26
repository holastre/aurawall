// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftE2E",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .testTarget(
            name: "AuraWallE2ETests",
            dependencies: [
                .product(name: "AuraWallCore", package: "AuraWall")
            ]
        )
    ]
)
