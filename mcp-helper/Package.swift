// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoringNotchMCP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "boringnotch-mcp", path: "Sources/boringnotch-mcp"),
    ]
)
