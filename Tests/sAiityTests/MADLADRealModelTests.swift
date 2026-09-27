import Foundation
import Testing

@testable import sAiity

/// Real-MADLAD checks, opt-in because they need the 1.86 GB weights.
///
///   SAIITY_MADLAD_SMOKE=1 swift test -c release -Xswiftc -enable-testing \
///     -Xswiftc -DSAIITY_TEST_HOOKS --filter MADLADRealModelTests
@Suite struct MADLADRealModelTests {
    private static let enabled =
        ProcessInfo.processInfo.environment["SAIITY_MADLAD_SMOKE"] == "1"

    /// The repository root, from this file's own location.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // sAiityTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    private static var appResources: URL {
        repoRoot.appendingPathComponent("build/sAiity.app/Contents/Resources")
    }

    @Test("MADLAD weights are fetched through the app's own downloader",
          .enabled(if: enabled), .timeLimit(.minutes(30)))
    func downloadWeights() async throws {
        if !MADLADTranslator.isDownloaded() {
            try await MADLADTranslator.downloadWeights { progress in
                if let f = progress.fraction {
                    FileHandle.standardError.write(Data(
                        "madlad download \(Int(f * 100))%\n".utf8))
                }
            }
        }
        #expect(MADLADTranslator.isDownloaded())
    }

    /// The shipped bundle must carry the MLX shader library, or translation
    /// refuses at runtime. Checked against the real bundle rather than the
    /// preflight's own default, because in a test process `Bundle.main` is the
    /// SwiftPM helper and has never held a metallib.
    ///
    /// Ungated on purpose — it needs no weights, only a built bundle.
    @Test("the built app bundle carries a non-empty MLX Metal library")
    func shippedBundleHasMetalLibrary() throws {
        try #require(FileManager.default.fileExists(atPath: Self.appResources.path),
                     "build/sAiity.app is missing — run ./build-app.sh first")
        #expect(TranslationPreflight.hasBundledMetalLibrary(resourceRoot: Self.appResources),
                "the app bundle would refuse to translate at runtime")
    }

    /// Real MADLAD inference: the only check here that says whether the feature
    /// works at all, rather than whether the plumbing around it is right.
    ///
    /// It does not run under `swift test`, and that is a property of the harness
    /// rather than of the code. MLX resolves its shader library through
    /// `NSBundle.mainBundle`, so it is found in the app — where `mainBundle` is
    /// the app and `Contents/Resources/default.metallib` sits beside the
    /// executable. In a SwiftPM test run `mainBundle` is the test helper inside
    /// the toolchain, so MLX reports "Failed to load the default metallib" and
    /// aborts natively. `TranslationPreflight` exists to turn exactly that
    /// uncatchable abort into a catchable refusal, so working around it here
    /// would defeat the guard rather than test the feature:
    ///
    ///   - `metalLibraryRootOverride` only satisfies the *check*. MLX does its
    ///     own lookup afterwards, so inference still aborts.
    ///   - `sAiityTests.xctest/Contents/MacOS/sAiityTests` is not a runnable
    ///     executable ("exec format error"), so the xctest cannot be made the
    ///     main bundle that way either.
    ///
    /// Disabled by default on purpose. Exercise it from the installed app.
    @Test("a real caption line is really translated",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_MADLAD_IN_APP"] == "1"),
          .timeLimit(.minutes(10)))
    func translatesACaption() async throws {
        #expect(MADLADTranslator.isDownloaded(), "run the download test first")
        try #require(FileManager.default.fileExists(atPath: Self.appResources.path),
                     "build/sAiity.app is missing — run ./build-app.sh first")
        MADLADTranslator.metalLibraryRootOverride = Self.appResources
        defer { MADLADTranslator.metalLibraryRootOverride = nil }
        let translator = MADLADTranslator()
        try await translator.prepare(from: "en", to: "de") { _ in }
        defer { Task { await translator.stop() } }

        let line = "We were discussing the roadmap for a while."
        let out = try await translator.translate(line, from: "en", to: "de")

        let value = try #require(out, "MADLAD returned nothing for a plain line")
        // The reported symptom was a translation that never arrived, or one that
        // came back as the input. Either must fail here.
        #expect(value.caseInsensitiveCompare(line) != .orderedSame,
                "the model echoed the input back instead of translating it")
        #expect(TranslationLanguage.baseCode(
            LanguageDetector.languageCode(in: value) ?? "") == "de",
            "expected German, got: \(value)")
        FileHandle.standardError.write(Data("de: \(value)\n".utf8))
    }

    /// The distinction the fix is about, on the real engine: a translator with
    /// no model loaded *declines* (nil). It must not throw, because a decline is
    /// routine and a throw now retires the engine.
    @Test("a translator with no model loaded declines rather than failing",
          .enabled(if: enabled), .timeLimit(.minutes(10)))
    func unloadedTranslatorDeclines() async throws {
        let translator = MADLADTranslator()
        let out = try await translator.translate("hello", from: "en", to: "de")
        #expect(out == nil, "an unloaded translator must decline, not fail")
    }
}
