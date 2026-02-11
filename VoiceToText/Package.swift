// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "whisper.spm", path: "LocalPackages/whisper.spm"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.30.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceToText",
            dependencies: [
                .product(name: "whisper", package: "whisper.spm"),
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "VoiceToText",
            exclude: ["Resources/Info.plist", "Resources/VoiceToText.entitlements"]
        ),
        .testTarget(
            name: "VoiceToTextTests",
            dependencies: ["VoiceToText"],
            path: "VoiceToTextTests"
        ),
    ]
)
