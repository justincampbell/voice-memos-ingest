// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "voice-memos-ingest",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // Declared explicitly: MCPHTTPHost imports Logging directly. It also
        // arrives transitively via swift-sdk/NIO, but relying on that would
        // break the build if either drops it.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "VMIngestCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // The MCP surface is a library, not part of the executable, so it can be
        // imported by tests — an executable target can't be. Everything here is
        // read-only over VMIngestCore.
        .target(
            name: "VMIngestMCP",
            dependencies: [
                "VMIngestCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "VoiceMemosIngest",
            dependencies: [
                "VMIngestCore",
                "VMIngestMCP"
            ]
        ),
        .executableTarget(
            name: "vmingest",
            dependencies: ["VMIngestCore"]
        ),
        .testTarget(
            name: "VMIngestCoreTests",
            dependencies: ["VMIngestCore"]
        ),
        .testTarget(
            name: "VMIngestMCPTests",
            dependencies: ["VMIngestMCP", "VMIngestCore"]
        ),
    ]
)
