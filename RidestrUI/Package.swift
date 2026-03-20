// swift-tools-version: 6.0
import PackageDescription

// RidestrUI — Optional companion UI components for the Ridestr protocol.
// Placeholder only. Implementation deferred to Phase 5.

let package = Package(
    name: "RidestrUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RidestrUI", targets: ["RidestrUI"]),
    ],
    dependencies: [
        .package(path: "../RidestrSDK"),
    ],
    targets: [
        .target(
            name: "RidestrUI",
            dependencies: [
                .product(name: "RidestrSDK", package: "RidestrSDK"),
            ]
        ),
        .testTarget(
            name: "RidestrUITests",
            dependencies: ["RidestrUI"]
        ),
    ]
)
