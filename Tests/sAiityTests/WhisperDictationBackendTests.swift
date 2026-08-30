import Foundation
import Testing
import WhisperKit

@testable import sAiity

@MainActor
struct WhisperDictationBackendTests {

    private func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/sAiity/WhisperDictationBackend.swift"), encoding: .utf8)
    }

    @Test("Whisper lifecycle uses the exact concrete API boundary")
    func concreteLifecycleContract() throws {
        let text = try source()
        #expect(text.contains("WhisperKit.download(variant: choice.identifier"))
        #expect(text.contains("downloadBase: partialRoot"))
        #expect(text.contains("useBackgroundSession: false"))
        #expect(text.contains("from: \"argmaxinc/whisperkit-coreml\""))
        #expect(text.contains("progressCallback: progress"))
        #expect(text.contains("setupModels(model: choice.identifier"))
        #expect(text.contains("loadModels(prewarmMode: true)"))
        #expect(text.contains("callback: nil"))
        #expect(text.contains("MelSpectrogram.mlmodelc"))
        #expect(text.contains("AudioEncoder.mlmodelc"))
        #expect(text.contains("TextDecoder.mlmodelc"))
    }

    @Test("Readiness is marker-last and recovery is concrete")
    func readinessAndRecoveryContract() throws {
        let text = try source()
        #expect(text.contains(".partial"))
        #expect(text.contains("write(to: marker"))
        #expect(text.contains("removeItem(at:"))
        #expect(text.contains("Task<URL, Error>"))
        #expect(text.contains("Task.checkCancellation()"))
    }

    @Test("Settings preparation is the only model construction boundary")
    func explicitSettingsBoundary() throws {
        let text = try source()
        #expect(text.contains("static func prepareModel"))
        #expect(text.contains("static func transcribe(samples:"))
        #expect(text.contains("try await WhisperKit(model: choice.identifier"))
    }

    @Test("Package manifest pins the exact WhisperKit dependency")
    func manifestPinsWhisperKit() throws {
        let package = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains(".package(url: \"https://github.com/argmaxinc/WhisperKit.git\", exact: \"1.0.0\")"))
        #expect(package.contains(".product(name: \"WhisperKit\", package: \"WhisperKit\")"))
    }

    @Test("WhisperKit dependency and model choices use the exact contract")
    func modelChoices() {
        #expect(WhisperDictationBackend.ModelChoice.allCases == [.base, .small])
        #expect(WhisperDictationBackend.ModelChoice.base.identifier == "openai_whisper-base")
        #expect(WhisperDictationBackend.ModelChoice.small.identifier == "openai_whisper-small")
        #expect(WhisperDictationBackend.ModelChoice.base.description == "base")
        #expect(WhisperDictationBackend.ModelChoice.small.description == "small")
        #expect(WhisperDictationBackend.ModelChoice.base.folderName == "whisper-openai_whisper-base")
        #expect(WhisperDictationBackend.ModelChoice.small.folderName == "whisper-openai_whisper-small")
        #expect(WhisperDictationBackend.ModelChoice.base.readinessMarkerName == ".saiity-ready")
        #expect(WhisperDictationBackend.ModelChoice.small.readinessMarkerName == ".saiity-ready")
    }

    @Test("Locale hints use a base language and disable detection")
    func regionalLocaleHint() throws {
        let german = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "de-DE"))
        #expect(german.language == "de")
        #expect(german.detectLanguage == false)
        let chinese = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "zh-Hant-TW"))
        #expect(chinese.language == "zh")
        #expect(chinese.detectLanguage == false)
    }

    @Test("Only the exact auto locale enables detection")
    func autoLocaleHint() throws {
        let options = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "auto"))
        #expect(options.language == nil)
        #expect(options.detectLanguage == true)
    }

    @Test("Unsupported locale fails before transcription")
    func unsupportedLocale() {
        #expect(throws: WhisperDictationError.unsupportedLocale("xx-YY")) {
            try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "xx-YY"))
        }
    }

    @Test("Unsupported locale is rejected before the transcription closure")
    func unsupportedLocaleDoesNotCallTranscription() {
        var callCount = 0
        #expect(throws: WhisperDictationError.unsupportedLocale("xx-YY")) {
            try WhisperDictationBackend.transcribe(locale: Locale(identifier: "xx-YY")) {
                callCount += 1
            }
        }
        #expect(callCount == 0)
    }

    @Test("Supported regional locale uses its base language")
    func regionalLocaleSupportBoundary() throws {
        let options = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "de-DE"))
        #expect(options.language == "de")
        #expect(throws: WhisperDictationError.unsupportedLocale("zz-ZZ")) {
            try WhisperDictationBackend.decodingOptions(for: Locale(identifier: "zz-ZZ"))
        }
    }
}
