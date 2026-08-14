// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalDictation", targets: ["LocalDictation"])
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            path: "Sources/LocalDictation"
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation"],
            path: "Tests/LocalDictationTests"
        )
    ]
)

