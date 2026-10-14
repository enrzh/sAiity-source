import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CaptionLiveTranslationTests {
    @Test("preview pacing responds to sustained load and power pressure, then recovers")
    func adaptivePacing() {
        var pacing = CaptionLiveTranslation.Pacing()
        let normal: Duration = .milliseconds(400)
        #expect(pacing.delay(base: normal, resourceLimited: false) == normal)
        #expect(pacing.delay(base: normal, resourceLimited: true) == .milliseconds(1500))
        pacing.record(seconds: 3)
        #expect(pacing.delay(base: normal, resourceLimited: false) == normal)
        pacing.record(seconds: 3); pacing.record(seconds: 3)
        #expect(pacing.delay(base: normal, resourceLimited: false) == .seconds(2))
        #expect(pacing.delay(base: normal, resourceLimited: true) == .seconds(2))
        for _ in 0..<20 { pacing.record(seconds: 0.1) }
        #expect(pacing.delay(base: normal, resourceLimited: false) == normal)
        #expect(pacing.delay(base: .seconds(3), resourceLimited: true) == .seconds(3))
        pacing.record(seconds: .nan)
        #expect(pacing.decodeSeconds.isFinite)
    }

    private func request(_ text: String, sentence: Int = 0, generation: Int = 1,
                         target: String = "de", engine: TranslationEngine = .madlad) -> CaptionLiveTranslation.Request {
        .init(text: text, sentenceID: sentence, sessionGeneration: generation,
              translatorGeneration: generation, source: "en", target: target, engine: engine)
    }

    @MainActor private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation {
                continuation = $0
                entered = true
            }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    private func wait(until ready: () -> Bool) async throws {
        while !ready() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("interim words coalesce before decoding without waiting for a speech pause")
    func coalescesInterimWords() async throws {
        var inputs: [String] = []
        var outputs: [String] = []
        let live = CaptionLiveTranslation(delay: .milliseconds(30), isCurrent: { _ in true },
            translate: { inputs.append($0.text); return "Übersetzt" },
            display: { value, _ in outputs.append(value) })
        live.submit(request("We"))
        live.submit(request("We should"))
        live.submit(request("We should ship today"))
        try await wait { !outputs.isEmpty }
        #expect(inputs == ["We should ship today"])
        #expect(outputs == ["Übersetzt"])
        live.submit(request("We should ship today"))
        #expect(!live.isBusy)
        await live.stop()
    }

    @Test("slow decoding retains only the newest revision and never overlaps inference")
    func latestWinsSequentially() async throws {
        let gate = Gate()
        var inputs: [String] = []
        var outputs: [String] = []
        var active = 0
        var peak = 0
        let live = CaptionLiveTranslation(delay: .milliseconds(1), isCurrent: { _ in true },
            translate: { request in
                active += 1; peak = max(peak, active)
                defer { active -= 1 }
                inputs.append(request.text)
                if inputs.count == 1 { await gate.wait() }
                return request.text
            }, display: { text, _ in outputs.append(text) })
        live.submit(request("First"))
        try await wait { gate.entered }
        for index in 1...100 { live.submit(request("Revision \(index)")) }
        gate.open()
        try await wait { outputs.count == 2 }
        #expect(inputs == ["First", "Revision 100"])
        #expect(peak == 1)
        await live.stop()
    }

    @Test("closing or clearing a sentence cancels queued previews and ignores a late native result")
    func closeCancelsDraft() async throws {
        let gate = Gate()
        var outputs: [String] = []
        var decodes = 0
        let live = CaptionLiveTranslation(delay: .milliseconds(1), isCurrent: { _ in true },
            translate: { _ in decodes += 1; await gate.wait(); return "stale draft" },
            display: { value, _ in outputs.append(value) })
        live.submit(request("Draft"))
        try await wait { gate.entered }
        live.submit(request("Queued"))
        live.invalidate()
        #expect(live.isBusy, "native state stays owned until its operation drains")
        gate.open()
        await live.stop()
        #expect(outputs.isEmpty)
        #expect(decodes == 1)
    }

    @Test("a new session waits for cancelled native work before decoding its own preview")
    func newSessionAfterCancellation() async throws {
        let gate = Gate()
        var inputs: [Int] = []
        var outputs: [Int] = []
        let live = CaptionLiveTranslation(delay: .milliseconds(1), isCurrent: { _ in true },
            translate: { request in
                inputs.append(request.sessionGeneration)
                if request.sessionGeneration == 1 { await gate.wait() }
                return request.text
            }, display: { _, request in outputs.append(request.sessionGeneration) })
        live.submit(request("Old session"))
        try await wait { gate.entered }
        live.invalidate()
        live.submit(request("New session", generation: 2))
        #expect(inputs == [1])
        gate.open()
        try await wait { outputs == [2] }
        #expect(inputs == [1, 2])
        await live.stop()
    }

    @Test("target or sentence changes cannot paint a stale translation")
    func staleTargetAndSentence() async throws {
        let gate = Gate()
        var target = "de"
        var sentence = 0
        var outputs: [String] = []
        let live = CaptionLiveTranslation(delay: .milliseconds(1),
            isCurrent: { $0.target == target && $0.sentenceID == sentence },
            translate: { _ in await gate.wait(); return "stale" }, display: { value, _ in outputs.append(value) })
        live.submit(request("Old target"))
        try await wait { gate.entered }
        target = "fr"; sentence = 1
        gate.open()
        try await wait { !live.isBusy }
        #expect(outputs.isEmpty)
        live.submit(request("Already stale"))
        try await wait { !live.isBusy }
        #expect(outputs.isEmpty)
    }

    @Test("resident native preview pacing under continuous updates",
          .timeLimit(.minutes(2)),
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_ADAPTIVE_TRANSLATION_BENCHMARK"] == "1"))
    func installedAdaptivePacing() async throws {
        try #require(HyMT2Translator.isDownloaded, "Installed Hy-MT2 required; no downloads")
        let engine = HyMT2Translator()
        let nativeGate = TranslationInferenceGate()
        try await engine.prepare(from: "auto", to: "de") { _ in }
        for run in 1...3 {
            for limited in [false, true] {
                var calls = 0
                var displayed = 0
                var decodeSeconds = 0.0
                var failures = 0
                let live = CaptionLiveTranslation(resourceLimited: { limited }, isCurrent: { _ in true }, translate: { request in
                    calls += 1
                    let began = ContinuousClock.now
                    defer {
                        let elapsed = began.duration(to: .now).components
                        decodeSeconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    }
                    do {
                        return try await nativeGate.run {
                            try await TranslationProcedure.translate([.init(text: request.text, source: "auto")],
                                                                     to: "de", engine: engine)
                        }
                    } catch {
                        if !Task.isCancelled { failures += 1 }
                        return nil
                    }
                }, display: { _, _ in displayed += 1 })
                for revision in 0..<80 {
                    live.submit(request("Can you send me the invoice today? \(revision)", engine: .hyMT2))
                    try await Task.sleep(for: .milliseconds(100))
                }
                await live.stop()
                #expect(failures == 0)
                #expect(displayed > 0)
                let finalBegan = ContinuousClock.now
                let final = try await nativeGate.run {
                    try await TranslationProcedure.translate([.init(text: "Please send me the invoice today.", source: "en")],
                                                             to: "de", engine: engine)
                }
                #expect(final?.localizedCaseInsensitiveContains("Rechnung") == true)
                let finalElapsed = finalBegan.duration(to: .now).components
                print("SAIITY_ADAPTIVE_PREVIEW " + String(decoding: try JSONSerialization.data(withJSONObject:
                    ["run": run, "resourceLimited": limited, "updates": 80, "nativeCalls": calls,
                     "displayed": displayed, "decodeSeconds": decodeSeconds,
                     "finalTranslationSeconds": Double(finalElapsed.seconds) + Double(finalElapsed.attoseconds) / 1e18]), as: UTF8.self))
            }
        }
        await engine.stop()
    }

    @Test("resident Hy-MT2 realtime preview latency",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_REALTIME_TRANSLATION_BENCHMARK"] == "1"))
    func installedPreviewLatency() async throws {
        try #require(HyMT2Translator.isDownloaded, "Installed Hy-MT2 required; no downloads")
        let engine = HyMT2Translator()
        let nativeGate = TranslationInferenceGate()
        try await engine.prepare(from: "auto", to: "de") { _ in }
        for (index, text) in ["Can you send me the invoice today?",
                             "Could you please die Rechnung öffnen?",
                             "你好，can you check the invoice?"].enumerated() {
            for run in 1...3 {
                var output: String?
                var failure: Error?
                let began = ContinuousClock.now
                let live = CaptionLiveTranslation(isCurrent: { _ in true }, translate: { request in
                    do {
                        return try await nativeGate.run {
                            try await TranslationProcedure.translate([.init(text: request.text, source: "auto")],
                                                                     to: "de", engine: engine)
                        }
                    } catch { failure = error; return nil }
                }, display: { value, _ in output = value })
                live.submit(request(text, sentence: index, engine: .hyMT2))
                let deadline = ContinuousClock.now + .seconds(20)
                while output == nil, failure == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                await live.stop()
                #expect(failure == nil)
                try #require(output?.isEmpty == false, "No realtime translated preview")
                #expect(output != text, "A preview must be translated, not returned unchanged")
                #expect(output!.localizedCaseInsensitiveContains("Rechnung"))
                let elapsed = began.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                print("SAIITY_REALTIME_PREVIEW " + String(decoding: try JSONSerialization.data(withJSONObject:
                    ["fixture": index, "run": run, "seconds": seconds, "coalescingMilliseconds": 400,
                     "model": "hy-mt2", "outputChars": output!.count]), as: UTF8.self))
            }
        }
        await engine.stop()
    }
}
