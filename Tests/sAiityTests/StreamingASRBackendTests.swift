import AVFoundation
import Testing

@testable import sAiity

@Suite struct StreamingASRBackendTests {
    final class FakeEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        var loads = 0
        var resets = 0
        var teardowns = 0

        func load(progress: @escaping @Sendable (String) -> Void) async throws {
            loads += 1
        }

        func reset() async {
            resets += 1
        }

        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {}
        func process(_ samples: [Float]) async throws {}
        func finishSession() async -> String? { nil }

        func teardown() async {
            teardowns += 1
        }

        func detectedLanguage() async -> String? { "en" }
    }

    @Test("stopping a streaming backend keeps it reusable until release")
    func stopPreservesLoadedEngine() async throws {
        let engine = FakeEngine()
        let backend = StreamingASRBackend(name: "Test", engine: engine)

        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { _ in }
        await backend.stop()

        #expect(engine.loads == 1)
        #expect(engine.teardowns == 0)

        try await backend.start { _ in }
        await backend.stop()
        await backend.release()

        #expect(engine.loads == 1)
        #expect(engine.resets >= 2)
        #expect(engine.teardowns == 1)
    }
}
