// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RidestrSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RidestrSDK", targets: ["RidestrSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/rust-nostr/nostr-sdk-swift.git", from: "0.44.0"),
    ],
    targets: [
        .target(
            name: "RidestrSDK",
            dependencies: [
                .product(name: "NostrSDK", package: "nostr-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "RidestrSDKTests",
            dependencies: ["RidestrSDK"]
        ),
    ]
)
