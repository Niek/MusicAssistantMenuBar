// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "musicassistant-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MusicAssistantMenuBar", targets: ["MusicAssistantMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "MusicAssistantMenuBar",
            path: "Sources/MusicAssistantMenuBar"
        ),
        .testTarget(
            name: "MusicAssistantMenuBarTests",
            dependencies: ["MusicAssistantMenuBar"],
            path: "Tests/MusicAssistantMenuBarTests"
        )
    ]
)
