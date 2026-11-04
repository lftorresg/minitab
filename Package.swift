// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MiniTab", path: "Sources/MiniTab")
    ]
)
