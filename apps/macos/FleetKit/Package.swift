// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FleetAPI", targets: ["FleetAPI"]),
        .executable(name: "FleetProbe", targets: ["FleetProbe"]),
    ],
    targets: [
        .target(
            name: "FleetAPI",
            path: "Sources/FleetAPI"
        ),
        .executableTarget(
            name: "FleetProbe",
            dependencies: ["FleetAPI"],
            path: "Sources/FleetProbe"
        ),
        .testTarget(
            name: "FleetAPITests",
            dependencies: ["FleetAPI"],
            path: "Tests/FleetAPITests"
        ),
    ]
)
