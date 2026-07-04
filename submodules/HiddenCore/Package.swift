// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiddenCore",
    platforms: [
        // The product ships iOS-only. `.macOS` is kept ONLY so `swift test` can
        // run the crypto/container/protocol suite on a Mac/CI host without the
        // full Telegram-iOS tree — it is not a shipping target.
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
