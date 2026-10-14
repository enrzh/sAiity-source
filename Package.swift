// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Syllivra",
    // SpeechAnalyzer / SpeechTranscriber are @available(anyAppleOS 26, *).
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Syllivra", targets: ["sAiity"])],
    dependencies: [
        // Nemotron is a genuinely streaming RNN-T on CoreML/ANE. The package
        // also carries the legacy EOU implementation used only by old local
        // data; the product exposes Nemotron alone.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        // MADLAD-400-3B-MT (T5 seq2seq) on MLX — the only Swift package that
        // compiles a dedicated translation model on this toolchain.
        // Pin the known-good revision. speech-swift still pins mlx-swift-lm to
        // its main branch transitively; the CI package-resolution check keeps
        // that drift visible until the upstream package publishes a release.
        .package(url: "https://github.com/soniqo/speech-swift",
                 revision: "37c99dd856cfacfe952b2e48ecdb3c9dedc77625"),
        // Qwen via llama.cpp/GGUF. Ships a binaryTarget, so no cmake.
        .package(url: "https://github.com/obra/LLM.swift",
                 revision: "c2144e1a0e29c280ec6080b7da85e876d51f8509"),
        // Already here transitively, under speech-swift. Declared explicitly so
        // the app can import MLX and bound its buffer pool: MLX caches freed GPU
        // buffers and its default ceiling is a fraction of physical RAM, which on
        // a 16 GB Mac means MADLAD's gigabytes are never returned to the system.
        // Pinned to the version speech-swift already resolves, so adding this
        // changes what we can call, not what gets built.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // In-app updates. Without this a shipped build can never be fixed after
        // the fact — a bad bug would live forever on every Mac that has it.
        .package(url: "https://github.com/sparkle-project/Sparkle",
                 exact: "2.9.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "sAiity",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MADLADTranslation", package: "speech-swift"),
                // For HuggingFaceDownloader: fetching MADLAD's weights without
                // also loading 1.86 GB into memory, which fromPretrained does.
                .product(name: "AudioCommon", package: "speech-swift"),
                "SaiityLLM",
                .product(name: "MLX", package: "mlx-swift"),
                // Qwen3-ASR 0.6B and 1.7B. Finals are append-only; partials are
                // not fed to the caption reconciler. SpeechVAD segments the
                // audio so a line is transcribed once, when the speaker pauses.
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/sAiity",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Keep test-only hooks available to local debug builds; release
                // builds pass no test-hook flags.
                .define("SAIITY_TEST_HOOKS", .when(configuration: .debug)),
            ]
        ),
        .target(name: "SaiityLLM",
                dependencies: [.product(name: "LLM", package: "LLM.swift")],
                path: "Vendor/SaiityLLM",
                exclude: ["README.md", "LICENSE"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Covers the pure logic only — the model registry and the per-engine
        // language mapping. Both are places where a wrong answer is silent:
        // a bad removal path deletes the wrong directory, and a bad language
        // code produces no translation and no error.
        .testTarget(
            name: "sAiityTests",
            dependencies: ["sAiity"],
            path: "Tests/sAiityTests",
            swiftSettings: [.swiftLanguageMode(.v5), .define("SAIITY_TEST_HOOKS")],
            // Sparkle is a dynamic framework living in the build products
            // directory, three levels up from the xctest binary. Without this
            // rpath the whole test bundle fails to dlopen — and SIP strips
            // DYLD_FRAMEWORK_PATH from the test runner, so an env var cannot
            // stand in for it.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath",
                                           "-Xlinker", "@loader_path/../../.."])]
        ),
    ]
)
