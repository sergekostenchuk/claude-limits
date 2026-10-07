// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeLimits", platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeLimits", targets: ["ClaudeLimits"])],
    targets: [
        .target(name: "ClaudeLimitsCore"),
        .executableTarget(name: "ClaudeLimits", dependencies: ["ClaudeLimitsCore"]),
        .testTarget(name: "ClaudeLimitsCoreTests", dependencies: ["ClaudeLimitsCore"])
    ]
)
