// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JMacTool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "JMacTool",
            targets: ["JMacTool"]
        )
    ],
    targets: [
        .target(
            name: "JMacToolCore",
            path: "Sources/JMacToolCore"
        ),
        .executableTarget(
            name: "JMacTool",
            dependencies: ["JMacToolCore"],
            path: "Sources/JMacToolApp"
        ),
        .testTarget(
            name: "JMacToolCoreTests",
            dependencies: ["JMacToolCore"],
            path: "Tests/JMacToolCoreTests"
        )
    ]
)
