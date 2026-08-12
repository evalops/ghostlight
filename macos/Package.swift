// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "GhostlightApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "GhostlightApp",
            targets: ["GhostlightApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GhostlightApp"
        ),
        .testTarget(
            name: "GhostlightAppTests",
            dependencies: ["GhostlightApp"]
        )
    ]
)
