// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DirectorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DirectorAPI", targets: ["DirectorAPI"]),
        .executable(name: "DirectorProbe", targets: ["DirectorProbe"]),
    ],
    targets: [
        .target(
            name: "DirectorAPI",
            path: "Sources/DirectorAPI"
        ),
        .executableTarget(
            name: "DirectorProbe",
            dependencies: ["DirectorAPI"],
            path: "Sources/DirectorProbe"
        ),
        .testTarget(
            name: "DirectorAPITests",
            dependencies: ["DirectorAPI"],
            path: "Tests/DirectorAPITests"
        ),
    ]
)
