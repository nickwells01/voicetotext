// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "whisper.spm", path: "LocalPackages/whisper.spm"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceToText",
            dependencies: [
                .product(name: "whisper", package: "whisper.spm"),
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "VoiceToText",
            exclude: ["Resources/Info.plist", "Resources/VoiceToText.entitlements"]
        ),
    ]
)
