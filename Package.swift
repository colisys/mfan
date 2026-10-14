// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "mfan",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MFan", targets: ["MFan"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    targets: [
        .target(name: "FanCore"),
        .executableTarget(
            name: "MFan",
            dependencies: ["FanCore"]
        ),
        .executableTarget(
            name: "fanctl",
            dependencies: ["FanCore"]
        ),
        .testTarget(
            name: "MFanTests",
            dependencies: ["MFan"]
        ),
        .testTarget(
            name: "FanServiceTests",
            dependencies: ["fanctl", "MFan", "FanCore"]
        ),
        .testTarget(
            name: "FanCoreTests",
            dependencies: ["FanCore"]
        ),
    ]
)
