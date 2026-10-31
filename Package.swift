// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceIt",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VoiceIt", targets: ["VoiceIt"]),
        .executable(name: "voice-it-harness", targets: ["VoiceItHarness"]),
        .executable(name: "voice-it-download", targets: ["VoiceItDownloadTool"]),
    ],
    dependencies: [
        // Pinned: the package has no version tags and its API has moved since the README.
        // `traits: []` switches off FluidAudio's text-to-speech, speaker-diarization and NeMo text-normalisation parts
        // (the last is a prebuilt binary). We only use Parakeet speech recognition.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "16d0a17471f3da6083b44aaea4c07d1989239140", traits: []),
        // Cleanup model runtime. Loaded from a local folder only: no downloader package is used.
        // 3.31.4 is the newest release that builds with Swift 6.2 (Xcode 26.3); newer ones need mlx-swift tools 6.3.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),   // the version mlx-swift-lm 3.31.4 resolves to
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Pure logic with no MLX or FluidAudio: fast to build and test with `swift test`.
        .target(name: "VoiceItLogic", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VoiceItLogicTests", dependencies: ["VoiceItLogic"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "VoiceItCore",
            dependencies: [
                "VoiceItLogic",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VoiceItCoreTests", dependencies: ["VoiceItCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VoiceIt", dependencies: ["VoiceItCore", "VoiceItDownloader"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The only code that uses the network: downloads the models listed in the manifest, with checksums. No ML dependencies, and nothing
        // else in the project may import it except the app's setup window and its own tool (a test enforces this).
        .target(name: "VoiceItDownloader", dependencies: ["VoiceItLogic"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VoiceItDownloadTool", dependencies: ["VoiceItDownloader"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VoiceItDownloaderTests", dependencies: ["VoiceItDownloader"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VoiceItHarness", dependencies: ["VoiceItCore"], path: "Sources/VoiceItHarness",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
