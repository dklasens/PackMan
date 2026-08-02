// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PackMan",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PackMan",
            path: "Sources/PackMan"
        ),
        .testTarget(
            name: "PackManTests",
            dependencies: ["PackMan"],
            path: "Tests/PackManTests",
            resources: [.process("Fixtures")]
        )
    ]
)
