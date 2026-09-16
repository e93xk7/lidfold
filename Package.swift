// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lidfold",
    platforms: [.macOS(.v14)],
    targets: [
        // Sensor + Signal + Mapping。純邏輯、不 import AppKit，方便用 CSV 回放做單元測試。
        .target(
            name: "LidFoldCore",
            path: "Sources/LidFoldCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // M0–M2 用的命令列工具
        .executableTarget(
            name: "lidfold-cli",
            dependencies: ["LidFoldCore"],
            path: "Sources/lidfold-cli"
        ),
        .testTarget(
            name: "LidFoldCoreTests",
            dependencies: ["LidFoldCore"],
            path: "Tests/LidFoldCoreTests"
        ),
    ]
)
