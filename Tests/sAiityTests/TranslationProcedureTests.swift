import Foundation
import Testing

@testable import sAiity

@Suite struct TranslationProcedureTests {
    @Test("an invalid batch slice is retried without repeating accepted slices")
    func pql4BatchValidation() async throws {
        let engine = Engine()
        engine.batch = ["Please 確認してください before continuing.", "This ends the meeting."]
        engine.outputs = ["Please check before continuing."]
        let result = try await TranslationProcedure.translate([
            .init(text: "続ける前に確認してください。", source: "ja"),
            .init(text: "Damit endet die Besprechung.", source: "de")
        ], to: "en", engine: engine)
        #expect(result == "Please check before continuing. This ends the meeting.")
        #expect(engine.inputs.map(\.source) == ["ja"])
    }

    @Test("a plausible slice cannot hide untranslated grammar in the assembled result")
    func pql4CombinedValidation() async throws {
        let engine = Engine()
        engine.batch = ["は", "い"]
        #expect(try await TranslationProcedure.translate([
            .init(text: "Please", source: "en"), .init(text: "continue", source: "en")
        ], to: "de", engine: engine) == nil)
        #expect(engine.inputs.isEmpty)
    }

    @Test("numeric-only regions retain the supplied source locale")
    func pql4SourceLocale() async throws {
        let engine = Engine()
        engine.outputs = ["1234"]
        #expect(try await TranslationProcedure.translate([
            .init(text: "1,234", source: "de")
        ], to: "en", engine: engine) == nil)
    }

    @Test("a cancelled request never enters batch translation")
    func pql4CancelledBatch() async {
        let engine = Engine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await TranslationProcedure.translate([
                    .init(text: "日本語の字幕を確認してください。", source: "ja"),
                    .init(text: "Bitte prüfen Sie die Rechnung.", source: "de")
                ], to: "en", engine: engine)
                Issue.record("cancelled translation returned")
            } catch { #expect(error is CancellationError) }
        }
        await task.value
        #expect(engine.batchCalls == 0)
        #expect(engine.inputs.isEmpty)
    }

    @Test("wrong-language and numerically incomplete sequential results preserve the original")
    func pql4SequentialValidation() async throws {
        for (source, output) in [
            ("Guten Morgen", "Bonjour"),
            ("Sende 2 Kopien an 2 Teams.", "Send 2 copies to the team.")
        ] {
            let engine = Engine()
            engine.outputs = [output]
            #expect(try await TranslationProcedure.translate([
                .init(text: source, source: "de")
            ], to: "en", engine: engine) == nil)
        }
    }

    @Test("PQL2 Chinese language identity cannot skip output script conversion")
    func pql2ChineseVariant() {
        #expect(TranslationLanguage.isSame("zh-Hans", as: "zh-Hant"))
        #expect(!TranslationProcedure.isAlreadyInTarget("我们今天需要检查这张发票并讨论会议安排。", target: "zh-Hant"))
        #expect(!TranslationProcedure.isAlreadyInTarget("我們今天需要檢查這張發票並討論會議安排。", target: "zh-Hans"))
        #expect(!TranslationProcedure.isAlreadyInTarget("字幕", target: "zh-Hant"))
    }

    @Test("PQL2 Japanese translation receives one complete coherent phrase", arguments: ["en", "de"])
    func pql2JapaneseTranslation(_ target: String) async throws {
        let text = "日本語の字幕を確認してください。"
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "zh")
        let engine = Engine()
        let expected = target == "en" ? "Please check the Japanese subtitles." : "Bitte prüfen Sie die japanischen Untertitel."
        // Enough replies to record a bad split as assertion failures, not an array trap.
        engine.outputs = Array(repeating: expected, count: max(1, spans.count))
        let result = try await TranslationProcedure.translate(
            spans.map { .init(text: $0.text, source: $0.language ?? "auto") },
            to: target, engine: engine)
        #expect(engine.inputs == [.init(text: text, source: "ja")])
        #expect(result == expected)
    }

    final class Engine: Translating, @unchecked Sendable {
        let name = "Test"
        var inputs: [TranslationRegion] = []
        var outputs: [String?] = []
        var batch: [String]?
        var batchCalls = 0
        var beforeTranslate: (() async throws -> Void)?
        func prepare(from: String, to: String, progress: @escaping @Sendable (String) -> Void) async throws {}
        func stop() async {}
        func translate(_ text: String, from source: String, to target: String) async throws -> String? {
            try await beforeTranslate?()
            inputs.append(.init(text: text, source: source))
            return outputs.removeFirst()
        }
        func translateRegions(_ regions: [TranslationRegion], to target: String) async throws -> [String]? {
            batchCalls += 1
            return batch
        }
    }

    @Test("mixed target-language hints and unknown spans are never silently skipped")
    func mixedAndUnknown() async throws {
        let engine = Engine()
        engine.outputs = ["Can you send me the invoice?", "Hello"]
        let result = try await TranslationProcedure.translate([
            .init(text: "Can you send mir bitte die Rechnung?", source: "en"),
            .init(text: "你好", source: "auto")
        ], to: "en", engine: engine)
        #expect(engine.inputs.count == 2)
        #expect(result == "Can you send me the invoice? Hello")
    }

    @Test("a declined region rejects the whole translation instead of returning mixed partial output")
    func completeOrFallback() async throws {
        let engine = Engine()
        engine.outputs = ["Hello", nil]
        #expect(try await TranslationProcedure.translate([
            .init(text: "Hallo", source: "de"), .init(text: "世界", source: "zh")
        ], to: "en", engine: engine) == nil)
    }

    @Test("cancellation leaves no late combined translation")
    func cancelledTranslation() async {
        actor Signal {
            var started = false
            func start() { started = true }
        }
        let signal = Signal()
        let engine = Engine()
        engine.outputs = ["Hello"]
        engine.beforeTranslate = {
            await signal.start()
            try await Task.sleep(for: .seconds(5))
        }
        let task = Task {
            return try await TranslationProcedure.translate([.init(text: "Hallo", source: "de")],
                to: "en", engine: engine)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await signal.started), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await signal.started)
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled translation returned") }
        catch { #expect(error is CancellationError) }
    }

    @Test("batch holes retry only that region and CJK boundaries add no spaces")
    func batchAndSpacing() async throws {
        let engine = Engine()
        engine.batch = ["你好", ""]
        engine.outputs = ["世界"]
        let result = try await TranslationProcedure.translate([
            .init(text: "Hello", source: "en"), .init(text: "world", source: "en")
        ], to: "zh", engine: engine)
        #expect(result == "你好世界")
        #expect(engine.inputs.map(\.text) == ["world"])
    }

    @Test("same-language skip requires strong text evidence and rejects code switching")
    func sourceHintsAreNotCommands() {
        #expect(!TranslationProcedure.isAlreadyInTarget("你好, please send mir die Rechnung", target: "en"))
        #expect(!TranslationProcedure.isAlreadyInTarget("Can you send mir bitte die Rechnung?", target: "en"))
        #expect(!TranslationProcedure.isAlreadyInTarget("maybe", target: "en"))
        #expect(!TranslationProcedure.isAlreadyInTarget("Can you bitte send it today?", target: "en"))
        #expect(!TranslationProcedure.isAlreadyInTarget("Can you open the Rechnung?", target: "en"))
    }
}
