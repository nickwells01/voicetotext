// swift-tools-version:5.3
import PackageDescription

#if arch(arm) || arch(arm64)
let platforms: [SupportedPlatform]? = [
    .macOS(.v11),
    .iOS(.v14),
    .watchOS(.v4),
    .tvOS(.v14)
]

// Metal target: ggml-metal.m needs -fno-objc-arc (manual retain/release)
let metalSettings: [CSetting] = [
    .unsafeFlags(["-fno-objc-arc"]),
    .define("GGML_USE_METAL"),
    .define("GGML_USE_ACCELERATE"),
    .headerSearchPath("../whisper/include")
]
let metalTargets: [Target] = [
    .target(
        name: "ggml-metal",
        path: "Sources/ggml-metal",
        publicHeadersPath: "include",
        cSettings: metalSettings,
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit")
        ]
    )
]
let metalDependencies: [Target.Dependency] = [.target(name: "ggml-metal")]

let whisperExclude: [String] = []
let whisperAdditionalSettings: [CSetting] = [
    .define("GGML_USE_METAL")
]
#else
let platforms: [SupportedPlatform]? = nil
let metalTargets: [Target] = []
let metalDependencies: [Target.Dependency] = []
let whisperExclude: [String] = ["Sources/whisper/ggml-metal.m", "Sources/whisper/ggml-metal.metal"]
let whisperAdditionalSettings: [CSetting] = []
#endif

let package = Package(
    name: "whisper.spm",
    platforms: platforms,
    products: [
        .library(
            name: "whisper",
            targets: ["whisper"])
    ],
    targets: metalTargets + [
        .target(
            name: "whisper",
            dependencies: metalDependencies,
            path: ".",
            exclude: whisperExclude,
            sources: [
                "Sources/whisper/ggml.c",
                "Sources/whisper/ggml-alloc.c",
                "Sources/whisper/ggml-backend.c",
                "Sources/whisper/ggml-quants.c",
                "Sources/whisper/coreml/whisper-encoder-impl.m",
                "Sources/whisper/coreml/whisper-encoder.mm",
                "Sources/whisper/whisper.cpp",
            ],
            resources: [
                .copy("Sources/whisper/ggml-metal.metal")
            ],
            publicHeadersPath: "Sources/whisper/include",
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("WHISPER_USE_COREML"),
                .define("WHISPER_COREML_ALLOW_FALLBACK")
            ] + whisperAdditionalSettings,
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        ),
        .target(name: "test-objc",  dependencies:["whisper"]),
        .target(name: "test-swift", dependencies:["whisper"])
    ],
    cxxLanguageStandard: CXXLanguageStandard.cxx11
)
