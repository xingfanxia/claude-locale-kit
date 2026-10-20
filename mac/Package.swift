// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeLocaleKit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "claude-locale", targets: ["claude-locale"]),
        .executable(name: "ClaudeLocaleKit", targets: ["ClaudeLocaleKit"]),
    ],
    targets: [
        .target(name: "ProfileCore"),
        .executableTarget(name: "claude-locale", dependencies: ["ProfileCore"]),
        .executableTarget(name: "ClaudeLocaleKit", dependencies: ["ProfileCore"]),
        .testTarget(name: "ProfileCoreTests", dependencies: ["ProfileCore"]),
    ]
)
