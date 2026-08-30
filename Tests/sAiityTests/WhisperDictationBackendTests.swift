import Foundation
import Testing
import WhisperKit

@testable import sAiity

@MainActor
struct WhisperDictationBackendTests {

    @Test("normal preparation downloads without constructing or loading Whisper")
    func normalPreparationOnlyDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [String] = []
        let backend = WhisperDictationBackend(
            download: { _, destination, _ in
                events.append("download")
                let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
                    try Data().write(to: folder.appendingPathComponent(name))
                }
                return folder
            },
            setup: { _, _ in events.append("setup") },
            load: { _, _ in events.append("load") })

        try await backend.prepareModel(.base, under: root)

        #expect(events == ["download"])
        #expect(!WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("Settings preparation loads before writing the readiness marker")
    func explicitPreparationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [String] = []
        let backend = WhisperDictationBackend(download: { _, destination, _ in
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { try Data().write(to: folder.appendingPathComponent(name)) }
            events.append("download"); return folder
        }, setup: { _, _ in events.append("setup") }, load: { _, _ in events.append("load") })
        try await backend.prepareModelForUse(.base, under: root)
        events.append(FileManager.default.fileExists(atPath: WhisperDictationBackend.modelFolder(for: .base, under: root).appendingPathComponent(".saiity-ready").path) ? "marker" : "missing")
        #expect(events == ["download", "setup", "load", "marker"])
        #expect(WhisperDictationBackend.isReady(.base, under: root))
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
