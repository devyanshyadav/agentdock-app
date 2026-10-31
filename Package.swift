// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentDock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AgentDock",
            targets: ["AgentDock"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AgentDock",
            path: "Sources/AgentDock"
        ),
        .testTarget(name: "AgentDockTests", dependencies: ["AgentDock"]),
    ]
)
