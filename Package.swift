// swift-tools-version: 6.0
import PackageDescription
import Foundation

let transcribeLibraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/CTranscribe/lib").path

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
        // The repository-owned MADLAD tokenizer uses this existing transitive pin.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
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
                "SaiityMADLAD",
                "CTranscribe",
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
            ],
            linkerSettings: [.unsafeFlags(["-L", transcribeLibraries,
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "SaiityLLM",
                dependencies: ["llama"],
                path: "Vendor/SaiityLLM",
                exclude: ["README.md", "LICENSE"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .binaryTarget(name: "llama",
                      url: "https://github.com/ggml-org/llama.cpp/releases/download/b11619/llama-b11619-xcframework.zip",
                      checksum: "8137660a3ad30a8115057e9eb8880cabb0f61e0ec37521b9738ddbb632ba7caf"),
        .systemLibrary(name: "CTranscribe", path: "Vendor/CTranscribe"),
        .target(name: "SaiityMADLAD",
                dependencies: [.product(name: "MLX", package: "mlx-swift"),
                               .product(name: "MLXNN", package: "mlx-swift"),
                               .product(name: "MLXFast", package: "mlx-swift"),
                               .product(name: "AudioCommon", package: "speech-swift"),
                               .product(name: "Tokenizers", package: "swift-transformers")],
                path: "Vendor/SaiityMADLAD", exclude: ["README.md", "LICENSE"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Covers the pure logic only — the model registry and the per-engine
        // language mapping. Both are places where a wrong answer is silent:
        // a bad removal path deletes the wrong directory, and a bad language
        // code produces no translation and no error.
        .testTarget(
            name: "sAiityTests",
            dependencies: ["sAiity", "SaiityLLM", "SaiityMADLAD", "CTranscribe"],
            path: "Tests/sAiityTests",
            swiftSettings: [.swiftLanguageMode(.v5), .define("SAIITY_TEST_HOOKS")],
            // Sparkle is a dynamic framework living in the build products
            // directory, three levels up from the xctest binary. Without this
            // rpath the whole test bundle fails to dlopen — and SIP strips
            // DYLD_FRAMEWORK_PATH from the test runner, so an env var cannot
            // stand in for it.
            linkerSettings: [.unsafeFlags(["-L", transcribeLibraries,
                                           "-Xlinker", "-rpath", "-Xlinker", transcribeLibraries,
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
    ]
)
