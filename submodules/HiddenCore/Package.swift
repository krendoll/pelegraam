// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiddenCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "HiddenCore", targets: ["HiddenCore"])
    ],
    targets: [
        .target(
            name: "HiddenCore",
            dependencies: []
        ),
        .testTarget(
            name: "HiddenCoreTests",
            dependencies: ["HiddenCore"]
        )
    ]
)
