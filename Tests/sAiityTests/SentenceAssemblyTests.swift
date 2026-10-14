import Foundation
import AVFoundation
import Testing

@testable import sAiity

extension SavedTranscriptOperationTests {
    @MainActor @Suite(.serialized)
    struct CaptionAssemblyIntegrationTests {
        @Test("caption translation receives a complete Japanese phrase and retains its original")
        func pql3JapaneseCaption() async throws {
            try await TranscriptTestLibrary.withTemporaryDirectory { _ in
                let defaults = UserDefaults.standard
                let oldTarget = defaults.object(forKey: "translateTo")
                let oldStyle = CaptionStyle.current
                var style = oldStyle
                style.hidden = true
                CaptionStyle.current = style
                let app = AppDelegate()
                let engine = TranslationProcedureTests.Engine()
                let original = "日本語の字幕を確認してください。"
                let translated = "Please check the Japanese subtitles."
                engine.outputs = [translated]
                defer {
                    app.setCaptionStateForTests(.idle)
                    CaptionStyle.current = oldStyle
                    if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                    else { defaults.removeObject(forKey: "translateTo") }
                }
                app.setCaptionStateForTests(.running)
                app.configureCaptionTranslatorForTests(engine, target: "en")
                app.renderCaptionForTests(.init(text: original, isFinal: true, start: 0, end: 1))
                await app.waitForCaptionTranslationsForTests()
                #expect(engine.inputs == [.init(text: original, source: "ja")])
                #expect(app.sessionLinesForTests.map(\.text) == [original])
                #expect(app.sessionLinesForTests.map(\.tr) == [translated])
                #expect(app.captionHistoryForTests.map(\.original) == [original])
            }
        }

        @Test("stopping waits for accepted final translations, patches and a pending Save")
        func stoppingDrainsFinalTranslations() async throws {
            try await TranscriptTestLibrary.withTemporaryDirectory { root in
                let defaults = UserDefaults.standard
                let oldTarget = defaults.object(forKey: "translateTo")
                let oldStyle = CaptionStyle.current
                var style = oldStyle
                style.hidden = true
                CaptionStyle.current = style
                let app = AppDelegate()
                let translator = HeldTranslator()
                defer {
                    app.setCaptionStateForTests(.idle)
                    CaptionStyle.current = oldStyle
                    if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                    else { defaults.removeObject(forKey: "translateTo") }
                }
                app.setCaptionStateForTests(.running)
                app.configureCaptionTranslatorForTests(translator, target: "de")
                await app.beginRecordingForTests()
                app.renderCaptionForTests(.init(text: "A complete sentence about shipping the project today.",
                                               isFinal: true, start: 0, end: 1))
                for _ in 0..<200 where !translator.entered { await Task.yield() }
                #expect(translator.entered)
                let saving = Task { await app.saveSubtitlesForTests() }
                await Task.yield()
                var stopped = false
                let stopping = Task { await app.stopCaptionsForTests(); stopped = true }
                for _ in 0..<200 { await Task.yield() }
                #expect(!stopped)
                #expect(CaptionSession.shared.isRunning && CaptionSession.shared.isStopping)
                if CaptionSession.shared.isStopping {
                    app.startCaptionsForTests()
                    #expect(!app.captionsActiveForTests)
                }
                translator.finish()
                await stopping.value
                let saved = try #require(await saving.value)
                #expect(saved.url.deletingLastPathComponent() == root)
                #expect(!CaptionSession.shared.isRunning && !CaptionSession.shared.isStopping)
                #expect(app.pendingTranscriptWritesForTests == 0)
                let sessions = TranscriptStore.list(in: root)
                #expect(sessions.count == 2)
                #expect(sessions.allSatisfy {
                    let lines = TranscriptStore.segments(of: $0)
                    return lines.count == 1 && lines[0].tr == "Eine vollständige Übersetzung."
                })
            }
        }

        @Test("Stop stops capture and cancels startup before a slow preview drains")
        func stoppingCapturesBeforePreviewDrains() async throws {
            try await TranscriptTestLibrary.withTemporaryDirectory { _ in
                let defaults = UserDefaults.standard
                let oldTarget = defaults.object(forKey: "translateTo")
                let oldTiming = defaults.object(forKey: "translationTiming")
                let oldStyle = CaptionStyle.current
                var style = oldStyle
                style.hidden = false
                style.showTranslation = true
                CaptionStyle.current = style
                TranslationTiming.current = .live
                let app = AppDelegate()
                let translator = HeldTranslator()
                var startupContinuation: CheckedContinuation<Void, Never>?
                defer {
                    translator.finish()
                    startupContinuation?.resume()
                    app.setCaptionStateForTests(.idle)
                    CaptionStyle.current = oldStyle
                    if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                    else { defaults.removeObject(forKey: "translateTo") }
                    if let oldTiming { defaults.set(oldTiming, forKey: "translationTiming") }
                    else { defaults.removeObject(forKey: "translationTiming") }
                }
                app.setCaptionStateForTests(.running)
                app.configureCaptionTranslatorForTests(translator, target: "de")
                let text = "A complete sentence about shipping the project today"
                app.renderCaptionForTests(.init(text: text, isFinal: false, start: 0, end: 1))
                let previewDeadline = ContinuousClock.now + .seconds(5)
                while !translator.entered, ContinuousClock.now < previewDeadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                try #require(translator.entered)
                app.renderCaptionForTests(.init(text: text, isFinal: true, start: 0, end: 1))
                let starting = Task { @MainActor in
                    await withCheckedContinuation { startupContinuation = $0 }
                }
                app.captionResourcesForTests.startTask = starting
                let startupDeadline = ContinuousClock.now + .seconds(5)
                while startupContinuation == nil, ContinuousClock.now < startupDeadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                try #require(startupContinuation != nil)
                var captureStopped = false
                app.captionResourcesForTests.onCaptureStoppedForTests = { captureStopped = true }
                var stopped = false
                let stopping = Task { await app.stopCaptionsForTests(); stopped = true }
                let stopDeadline = ContinuousClock.now + .seconds(2)
                while !captureStopped, ContinuousClock.now < stopDeadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                #expect(captureStopped, "a held preview must not keep audio capture running")
                #expect(app.captionHistoryForTests.isEmpty, "Stop must close the bubble before preview/final work drains")
                app.renderCaptionForTests(.init(text: "Synthetic late volatile speech", isFinal: false, start: 1, end: 2))
                #expect(app.captionHistoryForTests.isEmpty, "late native callbacks must not reopen a stopped bubble")
                #expect(starting.isCancelled, "startup must be cancelled before waiting on preview inference")
                #expect(app.captionStatusForTests == String(localized: "Stopping…"))
                #expect(!stopped && CaptionSession.shared.isRunning && CaptionSession.shared.isStopping)
                translator.finish()
                startupContinuation?.resume()
                startupContinuation = nil
                await stopping.value
                await app.waitForCaptionTranslationsForTests()
                #expect(app.sessionLinesForTests.map(\.text) == [text])
                #expect(app.sessionLinesForTests.map(\.tr) == ["Eine vollständige Übersetzung."])
                #expect(!CaptionSession.shared.isRunning && !CaptionSession.shared.isStopping)
            }
        }

        final class GapBackend: TranscriptionBackend, @unchecked Sendable {
            let name = "Caption boundary test"
            var drained: [Int] = []
            var flushes = 0
            var inputFormat: AVAudioFormat? { get async { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) } }
            func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {}
            func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {}
            func feed(_ buffer: AVAudioPCMBuffer) {}
            func stop() async {}
            func drain(toAudioSample sample: Int) async { drained.append(sample) }
            func flushPending() async { flushes += 1 }
        }

        @Test("revisions, punctuation, pauses, clear and stop keep complete committed captions")
        func captionBoundariesKeepWords() async throws {
            try await TranscriptTestLibrary.withTemporaryDirectory { _ in
                let oldStyle = CaptionStyle.current
                var style = oldStyle
                style.hidden = true
                CaptionStyle.current = style
                let app = AppDelegate()
                defer { app.setCaptionStateForTests(.idle); CaptionStyle.current = oldStyle }
                app.setCaptionStateForTests(.running)
                @MainActor func render(_ text: String, final: Bool = true) {
                    app.renderCaptionForTests(.init(text: text, isFinal: final, start: 0, end: 1))
                }
                render("We ship", final: false)
                render("We ship today.", final: false)
                render("We ship today.")
                #expect(app.sessionLinesForTests.map(\.text) == ["We ship today."])
                let backend = GapBackend()
                render("Please check,")
                await app.commitCaptionGapForTests(0..<48_000, backend: backend)
                #expect(app.sessionLinesForTests.count == 1)
                render("the invoice:")
                await app.commitCaptionGapForTests(0..<96_000, backend: backend)
                #expect(app.sessionLinesForTests.count == 1)
                render("it is ready")
                await app.commitCaptionGapForTests(0..<144_000, backend: backend)
                #expect(app.sessionLinesForTests.last?.text == "Please check, the invoice: it is ready")
                #expect(backend.drained == [16_000, 32_000, 48_000])
                #expect(backend.flushes == 3)
                let long = Array(repeating: "complete", count: 45).joined(separator: " ")
                render(long)
                #expect(app.sessionLinesForTests.last?.text == long)
                render("Keep this unfinished tail", final: false)
                app.clearCaptionForTests()
                #expect(app.sessionLinesForTests.last?.text == "Keep this unfinished tail")
                #expect(app.captionHistoryForTests.isEmpty)
                render("Captions resume without restarting.")
                #expect(app.captionHistoryForTests.map(\.original) == ["Captions resume without restarting."])
                render("Keep the stop tail")
                await app.stopCaptionsForTests()
                #expect(app.sessionLinesForTests.last?.text == "Keep the stop tail")
                #expect(!CaptionSession.shared.isRunning)
            }
        }

        @Test("bounded translation overload stays visible while original captions continue")
        func translationOverloadIsVisible() async {
            let defaults = UserDefaults.standard
            let oldTarget = defaults.object(forKey: "translateTo")
            let oldStyle = CaptionStyle.current
            var style = oldStyle
            style.hidden = true
            CaptionStyle.current = style
            let app = AppDelegate()
            let translator = HeldTranslator()
            defer {
                CaptionStyle.current = oldStyle
                CaptionSession.shared.setTranslationBacklogged(false)
                if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                else { defaults.removeObject(forKey: "translateTo") }
            }
            app.configureCaptionTranslatorForTests(translator, target: "de")
            for index in 0..<8 {
                app.renderCaptionForTests(.init(text: "Sentence \(index) about shipping the project today.",
                                               isFinal: true, start: Double(index), end: Double(index + 1)))
            }
            #expect(app.sessionLinesForTests.count == 8)
            #expect(CaptionSession.shared.translationBacklogged)
            for _ in 0..<200 where !translator.entered { await Task.yield() }
            translator.finish()
            await app.waitForCaptionTranslationsForTests()
            #expect(!CaptionSession.shared.translationBacklogged)
            #expect(app.sessionLinesForTests.count == 8)
        }

        @Test("bubble Save captures its library and keeps more than 50 committed lines")
        func bubbleSavesCompleteSession() async throws {
            try await TranscriptTestLibrary.withTemporaryDirectory { root in
                let defaults = UserDefaults.standard
                let oldTarget = defaults.object(forKey: "translateTo")
                let oldStyle = CaptionStyle.current
                var style = oldStyle
                style.hidden = true
                CaptionStyle.current = style
                defer {
                    CaptionStyle.current = oldStyle
                    if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                    else { defaults.removeObject(forKey: "translateTo") }
                }
                let app = AppDelegate()
                let sentences = (0..<65).map { "Sentence \($0) about shipping the project today." }
                for (index, text) in sentences.enumerated() {
                    app.renderCaptionForTests(.init(text: text, isFinal: true,
                                                   start: Double(index), end: Double(index + 1)))
                }
                #expect(app.captionHistoryForTests.count == 50)
                let saved = try #require(await app.saveSubtitlesForTests())
                defer {
                    if saved.url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                        try? FileManager.default.removeItem(at: saved.url)
                    }
                }
                #expect(saved.url.deletingLastPathComponent() == root)
                #expect(TranscriptStore.list(in: root).map(\.id) == [saved.id])
                #expect(saved.meta.lineCount == 65)
                #expect(TranscriptStore.segments(of: saved).map(\.text) == sentences)
            }
        }

        @MainActor final class HeldTranslator: Translating, @unchecked Sendable {
            let name = "Held caption translator"
            var entered = false
            var continuation: CheckedContinuation<Void, Never>?
            func prepare(from: String, to: String, progress: @escaping @Sendable (String) -> Void) async throws {}
            func translate(_ text: String, from: String, to: String) async throws -> String? {
                if !entered {
                    await withCheckedContinuation {
                        continuation = $0
                        entered = true
                    }
                }
                return "Eine vollständige Übersetzung."
            }
            func stop() async {}
            func finish() { continuation?.resume(); continuation = nil }
        }

        final class QueuedTranslator: Translating, @unchecked Sendable {
            let name = "Held translation queue"
            var calls = 0
            var continuation: CheckedContinuation<Void, Never>?
            var drain = false
            func prepare(from: String, to: String, progress: @escaping @Sendable (String) -> Void) async throws {}
            func translate(_ text: String, from: String, to: String) async throws -> String? {
                calls += 1
                if !drain { await withCheckedContinuation { continuation = $0 } }
                return "Eine vollständige Übersetzung. " + text.filter(\.isNumber)
            }
            func stop() async {}
            func finishOne() { continuation?.resume(); continuation = nil }
            func finishAll() { drain = true; finishOne() }
        }

        @Test("overflow stays visible until accepted translation work drains and skipped rows stay original")
        func overloadDoesNotPromiseSkippedTranslations() async {
            let defaults = UserDefaults.standard
            let oldTarget = defaults.object(forKey: "translateTo")
            let oldStyle = CaptionStyle.current
            var style = oldStyle
            style.hidden = true
            CaptionStyle.current = style
            defer {
                CaptionStyle.current = oldStyle
                CaptionSession.shared.setTranslationBacklogged(false)
                if let oldTarget { defaults.set(oldTarget, forKey: "translateTo") }
                else { defaults.removeObject(forKey: "translateTo") }
            }
            let app = AppDelegate()
            let translator = QueuedTranslator()
            app.configureCaptionTranslatorForTests(translator, target: "de")
            for index in 0..<8 {
                app.renderCaptionForTests(.init(text: "Sentence \(index) about shipping the project today.",
                                               isFinal: true, start: Double(index), end: Double(index + 1)))
            }
            let firstDeadline = ContinuousClock.now + .seconds(5)
            while translator.calls == 0, ContinuousClock.now < firstDeadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(translator.calls == 1)
            translator.finishOne()
            let secondDeadline = ContinuousClock.now + .seconds(5)
            while translator.calls < 2, ContinuousClock.now < secondDeadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(translator.calls == 2)
            #expect(CaptionSession.shared.translationBacklogged)
            translator.finishAll()
            await app.waitForCaptionTranslationsForTests()
            #expect(!CaptionSession.shared.translationBacklogged)
            #expect(app.sessionLinesForTests.prefix(4).allSatisfy { $0.tr != nil })
            for (index, line) in app.sessionLinesForTests.prefix(4).enumerated() {
                #expect(line.tr?.contains(String(index)) == true)
            }
            #expect(app.sessionLinesForTests.suffix(4).allSatisfy { $0.tr == nil })
        }

        @Test("a final translation two sentences late updates history with translation display on or off",
              arguments: [false, true])
        func lateTranslationPatchesHistory(showTranslation: Bool) async {
            let defaults = UserDefaults.standard
            let previousTarget = defaults.object(forKey: "translateTo")
            let previousStyle = CaptionStyle.current
            let app = AppDelegate()
            var style = previousStyle
            style.hidden = true
            style.showTranslation = showTranslation
            CaptionStyle.current = style
            defer {
                CaptionStyle.current = previousStyle
                if let previousTarget { defaults.set(previousTarget, forKey: "translateTo") }
                else { defaults.removeObject(forKey: "translateTo") }
            }
            let translator = HeldTranslator()
            app.configureCaptionTranslatorForTests(translator, target: "de")
            let sentences = ["First sentence about shipping today.", "Second sentence about checking the invoice.", "Third sentence about sending tomorrow's notes."]
            for (index, text) in sentences.enumerated() {
                app.renderCaptionForTests(.init(text: text, isFinal: true, start: Double(index), end: Double(index + 1)))
            }
            for _ in 0..<200 where !translator.entered { await Task.yield() }
            #expect(translator.entered)
            #expect(app.captionHistoryForTests.count == 3)
            translator.finish()
            await app.waitForCaptionTranslationsForTests()
            #expect(app.sessionLinesForTests.map(\.text) == sentences)
            #expect(app.captionHistoryForTests.first?.translation == "Eine vollständige Übersetzung.")
            #expect(app.captionHistoryForTests.map(\.original) == sentences)
        }
    }
}

/// The recogniser commits a clause every few seconds so that continuous speech
/// still produces captions. Shown one at a time those clauses replace each
/// other, so a sentence arrives as a series of two-word flashes — and each
/// fragment is translated without the rest of its sentence.
///
/// Measured before this was fixed: speaking "Untertitel für alles, was der Mac
/// abspielt" left `Mac abspielt` on screen, translated as `Mac plays.`
@MainActor
struct SentenceAssemblyTests {
    @Test("caption latency diagnostics distinguish a warm model from a cold start")
    func temperatureLabelsMatchModelState() {
        let app = AppDelegate()
        for warm in [false, true] {
            app.recordCaptionTimingForTests(warmStart: warm)
            let entries = Diagnostics.recentTimings.filter {
                ["captions.first-text", "captions.first-final", "captions.visible-lag"].contains($0.operation)
            }.prefix(3)
            #expect(entries.count == 3)
            #expect(entries.allSatisfy { $0.cold == !warm })
        }
    }

    @Test("Clauses are joined into one readable line")
    func joinsWithSpaces() {
        let parts = ["Untertitel für alles,", "was der", "Mac abspielt."]
        #expect(AppDelegate.joinClauses(parts) == "Untertitel für alles, was der Mac abspielt.")
    }

    @Test("A single clause is unchanged")
    func singleClause() {
        #expect(AppDelegate.joinClauses(["Hello."]) == "Hello.")
        #expect(AppDelegate.joinClauses([]) == "")
    }

    /// Chinese, Japanese and Thai are written without spaces between words.
    /// Inserting one produces text a native reader sees as broken — and gives a
    /// translator two tokens where the language has one.
    @Test("Spaceless scripts are joined without spaces")
    func spacelessScripts() {
        #expect(AppDelegate.joinClauses(["这是一个", "测试。"]) == "这是一个测试。")
        #expect(AppDelegate.joinClauses(["これは", "テストです。"]) == "これはテストです。")
        // A boundary between a spaceless script and Latin gets one readable
        // separator; only two spaceless-script runs stay tight.
        #expect(AppDelegate.joinClauses(["这是", "Mac"]) == "这是 Mac")
    }

    /// Korean uses Hangul but writes with spaces, so it must not be lumped in
    /// with the scripts that do not.
    @Test("Korean keeps its spaces")
    func koreanIsSpaced() {
        #expect(AppDelegate.joinClauses(["안녕하세요", "반갑습니다."]) == "안녕하세요 반갑습니다.")
    }

    @Test("Every terminator that ends a sentence is recognised")
    func terminators() {
        for end in [".", "!", "?", "…", "。", "！", "？"] {
            let last = Character(end)
            #expect(AppDelegate.sentenceTerminatorsForTests.contains(last),
                    "\(end) should close a sentence")
        }
        // A comma must NOT close one — it is exactly where the engine breaks a
        // clause, and closing there is the bug this whole file is about.
        for mid in [",", "、", "，", ";", ":"] {
            #expect(!AppDelegate.sentenceTerminatorsForTests.contains(Character(mid)),
                    "\(mid) is a clause break, not a sentence end")
        }
    }

    /// Without a cap, speech that never pauses and never gets punctuation would
    /// accumulate for the whole session and never be translated at all.
    @Test("The length cap is large enough for a real sentence and small enough to bound")
    func lengthCap() {
        #expect(AppDelegate.maxSentenceCharsForTests >= 180,
                "a long spoken sentence must fit without being chopped")
        #expect(AppDelegate.maxSentenceCharsForTests <= 400,
                "past this the bubble cannot show it anyway")

        // The cap is a capacity bound — what the four-line bubble can show — and
        // it is not a readability target. Those disagree, and the disagreement
        // is the known live-caption weakness rather than an oversight:
        //
        //   220 characters at CaptionTiming's 14/second needs ~15.7s to read,
        //   and arrives in roughly the 3s the sentence took to speak.
        //
        // Lowering it to Export.cueCharacterBudget (84) makes each caption
        // readable and costs nothing to implement, but chops a long sentence in
        // half to do it. The export spends *time* instead — several cues in
        // sequence — which the one-row live bubble cannot do without deferring
        // the paint behind the display advance.
        let readingSeconds = Double(AppDelegate.maxSentenceCharsForTests) / 14.0
        #expect(readingSeconds > 10,
                "if this ever drops below ~10s the cap and the export budget should be unified")
        #expect(Export.cueCharacterBudget < AppDelegate.maxSentenceCharsForTests,
                "the export splits a caption the live bubble shows whole")
    }
}
