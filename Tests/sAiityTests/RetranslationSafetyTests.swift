import Foundation
import Testing

@testable import sAiity

extension SavedTranscriptOperationTests {

/// Re-translating a saved transcript used to be the one inference path in the
/// app that ran outside `TranslationInferenceGate`. It loads and decodes the
/// same model the live caption path and dictation's own translation use, and
/// all three can be alive at once — the gate is the only thing standing between
/// two of them and one Metal runtime.
///
/// The other half is what may not happen *around* a run: deleting the model it
/// is decoding from, or the files it would fetch again.
///
/// `.serialized` because a run reports itself through one global flag
/// (`CaptionSession.shared.isRetranslating`) that the destructive-action checks
/// read: two of these running side by side would each see the other's run.
@MainActor
@Suite(.serialized) struct RetranslationSafetyTests {

    // MARK: - Fakes

    final class FakeTranslator: Translating, @unchecked Sendable {
        let name = "Fake translator"
        private(set) var prepareCalls = 0
        private(set) var translateCalls: [String] = []
        private(set) var stopCalls = 0
        var prepareError: (any Error)?
        /// Held per line, so a test can keep a run parked inside the gate.
        var beforeTranslate: (@Sendable (String) async -> Void)?
        var translateResult: @Sendable (String) throws -> String? = { "[\($0)]" }
        /// Thrown instead of returning, to model a native engine failure as
        /// opposed to the model declining a line.
        var translateError: (any Error)?

        func prepare(from source: String, to target: String,
                     progress: @escaping @Sendable (String) -> Void) async throws {
            prepareCalls += 1
            if let prepareError { throw prepareError }
        }

        func translate(_ text: String, from source: String, to target: String) async throws -> String? {
            translateCalls.append(text)
            await beforeTranslate?(text)
            if let translateError { throw translateError }
            return try translateResult(text)
        }

        func stop() async { stopCalls += 1 }
    }

    /// A gate operation a test can hold open by hand, and know when it is
    /// genuinely inside rather than merely scheduled.
    final class ManualGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// "That point was reached", set from anywhere and safe to await late.
    final class Signal: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var fired = false

        func fire() {
            fired = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            if fired { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    /// Bounded wait for `condition`, so a defect fails the expectation instead
    /// of hanging the suite.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    /// Bounded spin with nothing to wait for: gives queued work every chance to
    /// run, so "it did not happen" is an observation and not a race.
    private func letTheSchedulerRun() async {
        for _ in 0..<400 { await Task.yield() }
    }

    private func saveSession(_ texts: [String]) throws -> SessionRef {
        let segments = texts.enumerated().map { index, text in
            Segment(i: index, t0: Double(index), t1: Double(index) + 1,
                    text: text, loc: "en", tr: nil, trLoc: nil, words: nil)
        }
        return try TranscriptStore.saveSession(segments, locale: "en-US",
                                               translateTo: nil,
                                               startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// What the run has reported so far. Used to prove a run really reached
    /// the step under test: "prepare was not called yet" only means anything if
    /// the run got as far as trying.
    final class Notes: @unchecked Sendable {
        private var values: [String] = []
        func add(_ note: String) { values.append(note) }
        var count: Int { values.count }
    }

    private func finish(_ retranslator: Retranslator,
                        session: SessionRef,
                        target: String,
                        notes: Notes? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            Task {
                await retranslator.run(session: session, target: target,
                                       onProgress: { progress in
                                           notes?.add(progress.note)
                                       },
                                       onFinish: { continuation.resume(returning: $0) })
            }
        }
    }
    // MARK: - The gate

    @Test("loading the translator waits for the shared inference gate",
          .timeLimit(.minutes(1)))
    func prepareRunsThroughTheSharedGate() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["one", "two"])
            defer { TranscriptStore.delete(session) }

            let gate = TranslationInferenceGate()
            let held = ManualGate()
            // Somebody else is decoding. This run's own load must queue behind it.
            let holder = Task { try? await gate.run { await held.wait() } }
            await settle { held.entered }
            #expect(held.entered)

            let translator = FakeTranslator()
            let retranslator = Retranslator(gate: gate)
            retranslator.engineOverrideForTests = translator
            let notes = Notes()
            let finished = Task {
                await finish(retranslator, session: session, target: "de", notes: notes)
            }
            await settle { notes.count > 0 }

            #expect(translator.prepareCalls == 0,
                    "a multi-gigabyte load started while another call held the gate")
            #expect(translator.translateCalls.isEmpty)

            held.open()
            await holder.value
            let message = await finished.value

            #expect(message == nil)
            #expect(translator.prepareCalls == 1)
            #expect(translator.translateCalls == ["one", "two"])
            #expect(translator.stopCalls == 1)
            #expect(TranscriptStore.segments(of: session).map(\.tr) == ["[one]", "[two]"])
        }
    }

    @Test("two re-translations never decode at the same time",
          .timeLimit(.minutes(1)))
    func concurrentRunsSerialiseThroughTheGate() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let first = try saveSession(["alpha"])
            let second = try saveSession(["beta"])
            defer {
                TranscriptStore.delete(first)
                TranscriptStore.delete(second)
            }

            let gate = TranslationInferenceGate()
            let blocked = ManualGate()
            let started = Signal()
            let translator = FakeTranslator()
            translator.beforeTranslate = { _ in
                started.fire()
                await blocked.wait()
            }
            let retranslator = Retranslator(gate: gate)
            retranslator.engineOverrideForTests = translator
            let finished = Task { await finish(retranslator, session: first, target: "de") }
            await settle { started.fired }
            #expect(started.fired, "the first line never reached the translator")

            // A second run, over a different transcript. It must not reach its own
            // decoding while the first still holds the gate.
            let otherTranslator = FakeTranslator()
            let other = Retranslator(gate: gate)
            other.engineOverrideForTests = otherTranslator
            let otherFinished = Task { await finish(other, session: second, target: "de") }
            await letTheSchedulerRun()

            #expect(otherTranslator.translateCalls.isEmpty,
                    "a second re-translation decoded while the first still held the gate")

            blocked.open()
            _ = await finished.value
            _ = await otherFinished.value

            #expect(translator.translateCalls == ["alpha"])
            #expect(otherTranslator.translateCalls == ["beta"])
            #expect(translator.stopCalls == 1)
            #expect(otherTranslator.stopCalls == 1)
            #expect(TranscriptStore.segments(of: first).map(\.tr) == ["[alpha]"])
            #expect(TranscriptStore.segments(of: second).map(\.tr) == ["[beta]"])
        }
    }

    @Test("cancelling a run releases the model and leaves the transcript alone",
          .timeLimit(.minutes(1)))
    func cancellationReleasesTheModelAndKeepsTheTranscript() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["keep me"])
            defer { TranscriptStore.delete(session) }

            let translator = FakeTranslator()
            // Cancellation-cooperative on purpose: `cancelAndWait()` promises the
            // run has *unwound*, and a fake that ignored cancellation would be
            // testing the fake rather than the promise. A real decoder behaves this
            // way too — it stops as soon as it notices.
            let started = Signal()
            translator.beforeTranslate = { _ in
                started.fire()
                try? await Task.sleep(for: .seconds(30))
            }
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            let finished = Task { await finish(retranslator, session: session, target: "de") }
            await settle { started.fired }
            #expect(started.fired, "the run never reached the translator")

            await retranslator.cancelAndWait()
            let message = await finished.value

            #expect(message == "Cancelled — the transcript was not changed.")
            #expect(translator.stopCalls == 1, "the loaded model was not released")
            #expect(TranscriptStore.segments(of: session).map(\.tr) == [nil],
                    "a cancelled run wrote to the transcript")
            #expect(CaptionSession.shared.isRetranslating == false)
            #expect(retranslator.running == false)
        }
    }

    @Test("a load queued behind other inference is skipped when the run is cancelled",
          .timeLimit(.minutes(1)))
    func cancellationSkipsAQueuedLoad() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["never translated"])
            defer { TranscriptStore.delete(session) }

            let gate = TranslationInferenceGate()
            let held = ManualGate()
            let holder = Task { try? await gate.run { await held.wait() } }
            await settle { held.entered }
            #expect(held.entered)

            let translator = FakeTranslator()
            let retranslator = Retranslator(gate: gate)
            retranslator.engineOverrideForTests = translator
            let notes = Notes()
            let finished = Task {
                await finish(retranslator, session: session, target: "de", notes: notes)
            }
            await settle { notes.count > 0 }
            #expect(translator.prepareCalls == 0,
                    "the run never reached the load while the gate was held")

            // Cancel while the load is still queued, then let the gate go. The
            // queued load must be skipped rather than run anyway — the gate's own
            // cancellation is what makes that true.
            retranslator.cancel()
            held.open()
            await holder.value
            let message = await finished.value

            #expect(message == "Cancelled — the transcript was not changed.")
            #expect(translator.prepareCalls == 0,
                    "a cancelled run loaded the model after the gate freed")
            #expect(translator.translateCalls.isEmpty)
            #expect(translator.stopCalls == 1, "the model was not handed back")
            #expect(TranscriptStore.segments(of: session).map(\.tr) == [nil])
        }
    }

    @Test("a failed load is reported and the model is still released",
          .timeLimit(.minutes(1)))
    func failedPrepareReleasesTheModel() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            struct Boom: LocalizedError { var errorDescription: String? { "translator unavailable" } }
            let session = try saveSession(["line"])
            defer { TranscriptStore.delete(session) }

            let translator = FakeTranslator()
            translator.prepareError = Boom()
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator

            let message = await finish(retranslator, session: session, target: "de")

            #expect(message == "translator unavailable")
            #expect(translator.stopCalls == 1)
            #expect(translator.translateCalls.isEmpty)
            #expect(TranscriptStore.segments(of: session).map(\.tr) == [nil])
            #expect(retranslator.running == false)
        }
    }

    // MARK: - What may not happen around a run

    /// One test, one window with the global re-translation flag set: the flag
    /// lives on a shared singleton, so three separate tests would mean three
    /// chances to disturb whatever else is running.
    // MARK: - Declined versus failed

    /// The distinction the `Translating` protocol exists to keep: a nil is the
    /// model declining one line, a throw is the engine itself failing.
    ///
    /// This used to be unobservable, because every engine ended in `try?` and a
    /// native failure arrived as a nil. On the caption path that meant a Metal
    /// or decode error surfaced as "the model declined to translate this line" —
    /// the user saw their untranslated caption with no explanation and no log
    /// line, and the engine was never charged against the failure budget. On
    /// the dictation path the mirror image happened: one declined line retired
    /// the translator, and retiring MADLAD is terminal.
    @Test("an engine that declines one line still completes the run")
    func declinedLineCompletesTheRun() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["one", "two", "three"])
            defer { TranscriptStore.delete(session) }

            let translator = FakeTranslator()
            translator.translateResult = { text in text == "two" ? nil : "[\(text)]" }

            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            let message = await finish(retranslator, session: session, target: "de")

            // Nil is routine: the run reports partial translation rather than
            // pretending it was cancelled, and the good lines are still written.
            #expect(message != nil)
            #expect(!(message ?? "").localizedCaseInsensitiveContains("not been changed"))
            let stored = TranscriptStore.segments(of: session)
            #expect(stored[0].tr == "[one]")
            #expect(stored[1].tr == nil, "the declined line must keep whatever was there")
            #expect(stored[2].tr == "[three]")
        }
    }

    @Test("an engine that throws aborts the run and leaves the transcript alone")
    func thrownInferenceAbortsWithoutWriting() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["one", "two", "three"])
            defer { TranscriptStore.delete(session) }

            let translator = FakeTranslator()
            // Fail on the second line, after one has already been translated: a
            // half-translated transcript is the outcome to avoid.
            translator.translateResult = { line in
                if translator.translateCalls.count >= 2 { throw EngineFailure() }
                return "[\(line)]"
            }

            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            let message = await finish(retranslator, session: session, target: "de")

            // A throw is a failure, not a decline, so the run stops rather than
            // counting the line and carrying on to the third.
            #expect(translator.translateCalls.count == 2,
                    "the run kept going after the engine failed")
            #expect(message != nil, "a failed run must say so rather than reporting plain success")
            let stored = TranscriptStore.segments(of: session)
            #expect(stored.allSatisfy { $0.tr == nil },
                    "a failed re-translation must not leave a half-written transcript")
        }
    }

    struct EngineFailure: Error {}

    @Test("a late translation patch survives retranslation publication")
    func latePatchSurvivesRetranslation() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["keep this line"])
            let file = session.url.appendingPathComponent("segments.jsonl")
            let translator = FakeTranslator()
            let held = ManualGate()
            translator.beforeTranslate = { _ in await held.wait() }
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            let run = Task { await finish(retranslator, session: session, target: "de") }
            await settle { held.entered }
            #expect(held.entered)
            try await TranscriptStore.shared.appendTranslation("late patch", to: .init(session: session.url, index: 0), target: "fr")
            let patched = try Data(contentsOf: file)
            held.open()
            #expect(await run.value != nil)
            #expect(try Data(contentsOf: file) == patched)
            #expect(TranscriptStore.segments(of: session).first?.tr == "late patch")
        }
    }

    @Test("a final spoken line survives retranslation publication")
    func finalSpokenLineSurvivesRetranslation() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let store = TranscriptStore.shared
            try await store.begin(locale: "en", translateTo: nil)
            try await store.append(.init(text: "first line", isFinal: true, start: 0, end: 1, words: []), locale: "en", translation: nil, translateTo: nil)
            let session = try #require(TranscriptStore.list().first)
            let translator = FakeTranslator()
            let held = ManualGate()
            translator.beforeTranslate = { _ in await held.wait() }
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            let run = Task { await finish(retranslator, session: session, target: "de") }
            await settle { held.entered }
            #expect(held.entered)
            try await store.append(.init(text: "final spoken line", isFinal: true, start: 1, end: 2, words: []), locale: "en", translation: nil, translateTo: nil)
            try await store.end()
            let file = session.url.appendingPathComponent("segments.jsonl")
            let appended = try Data(contentsOf: file)
            held.open()
            #expect(await run.value != nil)
            #expect(try Data(contentsOf: file) == appended)
            #expect(TranscriptStore.segments(of: session).map(\.text) == ["first line", "final spoken line"])
        }
    }

    @Test("retranslation decodes captured bytes instead of a stale cached generation")
    func retranslationUsesCapturedBytes() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["original"])
            let file = session.url.appendingPathComponent("segments.jsonl")
            let fixedModified = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: fixedModified], ofItemAtPath: file.path)
            let bytes = try Data(contentsOf: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let modified = try #require(attributes[.modificationDate] as? Date)
            let cachedSegments = TranscriptStore.segments(from: bytes)
            #expect(TranscriptStore.segments(of: session).first?.text == "original")
            let replacement = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "original", with: "modified").utf8)
            #expect(replacement.count == bytes.count)
            try replacement.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            let actualAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((actualAttributes[.size] as? NSNumber)?.intValue == bytes.count)
            let actualModified = try #require(actualAttributes[.modificationDate] as? Date)
            #expect(actualModified == modified)
            // Seed the actual file stamp explicitly: filesystem timestamp
            // roundtrips must not turn the stale-cache arrangement into a miss.
            SegmentCache.shared.store(cachedSegments, for: file.path,
                stamp: .init(modified: actualModified, size: bytes.count))
            #expect(TranscriptStore.segments(of: session).first?.text == "original",
                    "the stale same-size generation must really be cached")
            let translator = FakeTranslator()
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            #expect(await finish(retranslator, session: session, target: "de") == nil)
            #expect(translator.translateCalls == ["modified"])
            #expect(TranscriptStore.segments(of: session).first?.text == "modified")
        }
    }

    @Test("concurrent retranslation of one session publishes only one captured generation")
    func concurrentSameSessionPublication() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["one source"])
            let gate = TranslationInferenceGate()
            let held = ManualGate()
            let firstEngine = FakeTranslator()
            firstEngine.beforeTranslate = { _ in await held.wait() }
            firstEngine.translateResult = { _ in "first translation" }
            let first = Retranslator(gate: gate)
            first.engineOverrideForTests = firstEngine
            let firstRun = Task { await finish(first, session: session, target: "de") }
            await settle { held.entered }
            #expect(held.entered)
            let secondEngine = FakeTranslator()
            secondEngine.translateResult = { _ in "second translation" }
            let second = Retranslator(gate: gate)
            second.engineOverrideForTests = secondEngine
            let notes = Notes()
            let secondRun = Task { await finish(second, session: session, target: "fr", notes: notes) }
            await settle { notes.count > 0 }
            #expect(notes.count > 0, "both runs must capture the original generation")
            held.open()
            let messages = await [firstRun.value, secondRun.value]
            #expect(messages.filter { $0 == nil }.count == 1)
            #expect(messages.filter { $0 != nil }.count == 1)
            #expect(["first translation", "second translation"].contains(TranscriptStore.segments(of: session).first?.tr ?? ""))
            #expect(firstEngine.stopCalls == 1 && secondEngine.stopCalls == 1)
        }
    }

    @Test("retention defers while saved transcript work or live resources are busy")
    func retentionDefersProtectedWork() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let previousDays = TranscriptRetention.days
            defer { TranscriptRetention.days = previousDays }
            TranscriptRetention.days = 7
            let session = try TranscriptStore.saveSession([Segment(i: 0, t0: 0, t1: 1, text: "keep me", loc: "en", tr: nil, trLoc: nil, words: nil)], locale: "en", translateTo: nil, startedAt: Date().addingTimeInterval(-30 * 86_400))
            let file = session.url.appendingPathComponent("segments.jsonl")
            let original = try Data(contentsOf: file)
            #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            #expect(TranscriptStore.sessionsDir == root)
            #expect(session.url.deletingLastPathComponent() == root)
            #expect(TranscriptRetention.days == 7)
            #expect(TranscriptStore.sessionsOlderThan(days: 7, in: root).map(\.url) == [session.url])
            CaptionSession.shared.setSummarizing(true)
            let summarySweep = await TranscriptRetention.sweep()
            CaptionSession.shared.setSummarizing(false)
            #expect(summarySweep.deleted == 0 && summarySweep.failed == 0)
            #expect((try? Data(contentsOf: file)) == original)
            CaptionSession.shared.beginRetranslation()
            let translationSweep = await TranscriptRetention.sweep()
            CaptionSession.shared.endRetranslation()
            #expect(translationSweep.deleted == 0 && translationSweep.failed == 0)
            #expect((try? Data(contentsOf: file)) == original)
            CaptionSession.shared.setRunning(true)
            let liveSweep = await TranscriptRetention.sweep()
            CaptionSession.shared.setRunning(false)
            #expect(liveSweep.deleted == 0 && liveSweep.failed == 0)
            #expect((try? Data(contentsOf: file)) == original)
        }
    }

    @Test("retention uses its captured library and rechecks admission after listing")
    func retentionChecksFinalAdmission() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let days = TranscriptRetention.days
            defer {
                TranscriptRetention.days = days
                TranscriptRetention.afterListingForTests = nil
                CaptionSession.shared.setSummarizing(false)
            }
            TranscriptRetention.days = 7
            let old = try TranscriptStore.saveSession([Segment(i: 0, t0: 0, t1: 1, text: "expired temporary fixture", loc: "en", tr: nil, trLoc: nil, words: nil)],
                locale: "en", translateTo: nil, startedAt: Date().addingTimeInterval(-30 * 86_400))
            let file = old.url.appendingPathComponent("segments.jsonl")
            let original = try Data(contentsOf: file)
            #expect(TranscriptStore.sessionsDir == root)
            TranscriptRetention.afterListingForTests = { CaptionSession.shared.setSummarizing(true) }
            let protected = await TranscriptRetention.sweep()
            #expect(protected.deleted == 0 && protected.failed == 0)
            #expect(try Data(contentsOf: file) == original)
            CaptionSession.shared.setSummarizing(false)
            TranscriptRetention.afterListingForTests = nil
            let idle = await TranscriptRetention.sweep()
            #expect(idle.deleted == 1 && idle.failed == 0)
            #expect(!FileManager.default.fileExists(atPath: old.url.path))
        }
    }

    @Test("cancelling during snapshot capture drains the owned task without loading a model")
    func cancellationDuringSnapshotCapture() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let session = try saveSession(["unchanged"])
            let file = session.url.appendingPathComponent("segments.jsonl")
            let original = try Data(contentsOf: file)
            let held = ManualGate()
            let translator = FakeTranslator()
            let retranslator = Retranslator(gate: TranslationInferenceGate())
            retranslator.engineOverrideForTests = translator
            retranslator.beforeSnapshotReadForTests = { await held.wait() }
            let run = Task { await finish(retranslator, session: session, target: "de") }
            await settle { held.entered }
            #expect(held.entered)
            var drained = false
            retranslator.cancel()
            let cancellation = Task { await retranslator.cancelAndWait(); drained = true }
            await letTheSchedulerRun()
            #expect(!drained)
            #expect(CaptionSession.shared.isProcessingTranscript && retranslator.running)
            held.open()
            await cancellation.value
            #expect(await run.value == String(localized: "Cancelled — the transcript was not changed."))
            #expect(translator.prepareCalls == 0 && translator.translateCalls.isEmpty)
            #expect(translator.stopCalls == 1)
            #expect(try Data(contentsOf: file) == original)
            #expect(!CaptionSession.shared.isProcessingTranscript && !retranslator.running)
        }
    }

    @Test("destructive model actions refuse while a transcript is being re-translated")
    func destructiveActionsRefuseWhileRetranslating() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("saiity-retranslate-\(UUID().uuidString)")
            let weights = root.appendingPathComponent("weights.bin", isDirectory: false)
            let partial = root.appendingPathComponent("interrupted", isDirectory: true)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 64).write(to: weights)
            try Data(repeating: 4, count: 32)
                .write(to: partial.appendingPathComponent("weights.part"))
            defer { try? FileManager.default.removeItem(at: root) }

            let asset = ModelAsset(
                id: "test.retranslate.delete", family: .translation, title: "Translator",
                detail: "", recommended: false, licence: nil, advertisedBytes: nil,
                storage: .file(weights, expectedBytes: 64),
                removal: .remove(weights), use: .never, install: nil)
            let partialAsset = ModelAsset(
                id: "test.retranslate.partial", family: .translation, title: "Interrupted",
                detail: "", recommended: false, licence: nil, advertisedBytes: nil,
                storage: .directory(partial, markers: ["weights.part"]),
                removal: .remove(partial), use: .never, install: nil)

            let expected = "Translating a saved transcript — wait for that to finish, or cancel it"
            let state = AppState()
            state.assets = [ModelRegistry.status(of: asset), ModelRegistry.status(of: partialAsset)]
            let app = AppDelegate()

            CaptionSession.shared.beginRetranslation()
            await state.delete(asset)
            let cleared = await state.clearInterruptedDownloads(includeRetired: false)
            let removed = await state.removeAllDownloads()
            let quiesced = await app.prepareForModelCleanup()
            CaptionSession.shared.endRetranslation()

            #expect(state.modelError == expected)
            #expect(cleared == nil)
            #expect(removed == nil)
            #expect(quiesced == false)
            #expect(FileManager.default.fileExists(atPath: weights.path),
                    "the weights were unlinked from under a running re-translation")
            #expect(FileManager.default.fileExists(
                atPath: partial.appendingPathComponent("weights.part").path),
                "an interrupted download was cleared from under a running re-translation")
        }
    }
}
}
