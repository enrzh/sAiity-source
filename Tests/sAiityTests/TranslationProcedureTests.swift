import Foundation
import Testing

@testable import sAiity

@Suite struct TranslationProcedureTests {
    final class Engine: Translating, @unchecked Sendable {
        let name = "Test"
        var inputs: [TranslationRegion] = []
        var outputs: [String?] = []
        var batch: [String]?
        var beforeTranslate: (() async throws -> Void)?
        func prepare(from: String, to: String, progress: @escaping @Sendable (String) -> Void) async throws {}
        func stop() async {}
        func translate(_ text: String, from source: String, to target: String) async throws -> String? {
            try await beforeTranslate?()
            inputs.append(.init(text: text, source: source))
            return outputs.removeFirst()
        }
        func translateRegions(_ regions: [TranslationRegion], to target: String) async throws -> [String]? { batch }
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
