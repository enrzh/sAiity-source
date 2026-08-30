import Foundation
import Testing
import WhisperKit

@testable import sAiity

@MainActor
struct WhisperDictationBackendTests {

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
}
