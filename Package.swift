// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sAiity",
    // SpeechAnalyzer / SpeechTranscriber are @available(anyAppleOS 26, *).
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet + a genuinely streaming Nemotron RNN-T, both CoreML/ANE.
        // Zero external dependencies of its own, which is why it is preferred
        // over the MLX route to the same Nemotron checkpoint.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        // Whisper, for one-pass speech -> English translation. MIT, weights MIT.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // MADLAD-400-3B-MT (T5 seq2seq) on MLX — the only Swift package that
        // compiles a dedicated translation model on this toolchain.
        // NOTE: this package pins mlx-swift-lm to branch "main", so builds are
        // not fully reproducible through it. Pin explicitly if that bites.
        .package(url: "https://github.com/soniqo/speech-swift", branch: "main"),
        // Qwen via llama.cpp/GGUF. Ships a binaryTarget, so no cmake.
        .package(url: "https://github.com/obra/LLM.swift",
                 revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
    ],
    targets: [
        .executableTarget(
            name: "sAiity",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MADLADTranslation", package: "speech-swift"),
                // For HuggingFaceDownloader: fetching MADLAD's weights without
                // also loading 1.86 GB into memory, which fromPretrained does.
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "LLM", package: "LLM.swift"),
            ],
            path: "Sources/sAiity",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Covers the pure logic only — the model registry and the per-engine
        // language mapping. Both are places where a wrong answer is silent:
        // a bad removal path deletes the wrong directory, and a bad language
        // code produces no translation and no error.
        .testTarget(
            name: "sAiityTests",
            dependencies: ["sAiity"],
            path: "Tests/sAiityTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
