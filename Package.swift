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
        // CSV 回放測試。做成執行檔而不是 XCTest target：
        // 這台機器只裝了 Command Line Tools，沒有完整 Xcode，`swift test` 找不到 XCTest。
        .executableTarget(
            name: "lidfold-replay",
            dependencies: ["LidFoldCore"],
            path: "Sources/lidfold-replay"
        ),
    ]
)
