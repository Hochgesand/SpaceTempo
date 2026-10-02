// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceTempo",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SpaceTempoApp", path: "Sources/SpaceTempoApp")
    ]
)
