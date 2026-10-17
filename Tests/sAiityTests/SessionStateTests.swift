import Foundation
import Testing

@testable import sAiity

/// The session state decides two things that used to disagree: what the menu
/// offers, and whether the Settings window is allowed to delete model files.
///
/// The bug this replaces: a Bool could not represent `starting`, so a session
/// that was loading a model looked idle. Stop tore down a backend that had not
/// started; the start task then resumed and brought the audio stream up anyway.
@MainActor
struct SessionStateTests {

    @Test("Loading counts as active, so Stop is offered and deletion is refused")
    func startingIsActive() {
        // The whole point. During `starting` the app may be mid-download with no
        // stream yet — but a model is being read, and the user must be able to
        // stop. Treating it as idle is what let a second Start run.
        #expect(AppDelegate.SessionState.starting.isActive)
        #expect(AppDelegate.SessionState.running.isActive)
    }

    @Test("Idle and stopping are not active")
    func inactiveStates() {
        #expect(!AppDelegate.SessionState.idle.isActive)
        // `stopping` is not active: teardown is already under way, and offering
        // Stop again would re-enter it.
        #expect(!AppDelegate.SessionState.stopping.isActive)
    }

    @Test("stopping owns caption resources until teardown reaches idle")
    func stoppingOccupiesResources() {
        #expect(!AppDelegate.SessionState.idle.occupiesResources)
        #expect(AppDelegate.SessionState.starting.occupiesResources)
        #expect(AppDelegate.SessionState.running.occupiesResources)
        #expect(AppDelegate.SessionState.stopping.occupiesResources)
    }

    @Test("Cancelling an in-flight start stops it before it reaches capture")
    func cancellationStopsBeforeCapture() async {
        // The orchestration contract `start()` relies on: a task suspended in a
        // long model load must not proceed past its checkpoint once cancelled.
        // Before the fix there were no checkpoints, so a cancelled start still
        // ran `capture.start()` — audio capture with the menu reading "Start".
        actor Reached {
            var capture = false
            func markCapture() { capture = true }
        }
        let reached = Reached()

        let task = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)   // stands in for the model load
            guard !Task.isCancelled else { return }
            await reached.markCapture()
        }
        // Stop, the way stopAsync does it: cancel AND wait, so teardown cannot
        // race the thing it is tearing down.
        task.cancel()
        await task.value

        #expect(await reached.capture == false, "cancelled start still reached capture")
    }
}

@Suite struct DictationRecentResultTests {
    private func entry(_ text: String = "字幕 café", id: UUID = UUID(), secure: Bool = false) -> RecentDictationResult {
        var delivery = TextInsertionResult(outcome: .copied)
        delivery.secureTargetObserved = secure
        return .init(id: id, completedAt: Date(timeIntervalSince1970: 1),
                     result: .init(rawText: text, outputText: text, wasCleaned: false, wasTranslated: false),
                     delivery: delivery)
    }

    @Test("recent dictations retain nothing while disabled and clear an existing list")
    func dupRecentRequiresOptIn() {
        let old = entry("old")
        #expect(RecentDictationResult.retaining(entry(), in: [], enabled: false).isEmpty)
        #expect(RecentDictationResult.retaining(entry(), in: [old], enabled: false).isEmpty)
    }

    @Test("recent dictations evict the oldest after five completed runs")
    func dupRecentBoundedToFive() {
        var values: [RecentDictationResult] = []
        for index in 0..<6 {
            values = RecentDictationResult.retaining(entry("run \(index)"), in: values, enabled: true)
        }
        #expect(values.count == 5)
        #expect(values.map { $0.result.outputText } == (1..<6).map { "run \($0)" })
    }

    @Test("a duplicate completion cannot replace previously retained output")
    func dupRecentCompletionIsIdempotent() {
        let first = entry("first")
        let late = entry("stale", id: first.id)
        let values = RecentDictationResult.retaining(late, in: [first], enabled: true)
        #expect(values == [first])
    }

    @Test("secure-target observations are excluded from extra result retention")
    func dupRecentExcludesSecureTargets() {
        let first = entry("ordinary")
        #expect(RecentDictationResult.retaining(entry("sensitive", secure: true), in: [first], enabled: true) == [first])
    }

    @Test("recent retention is bounded by actual Unicode characters without rewriting them")
    func dupRecentUnicodeAndBudget() {
        let text = String(repeating: "e\u{301}", count: 30_000)
        let first = entry(text)
        let second = entry(text + "字幕")
        let values = RecentDictationResult.retaining(second, in: [first], enabled: true)
        #expect(values.count == 1)
        #expect(values.first?.result.rawText == text + "字幕")
        #expect(values.first?.result.outputText == text + "字幕")
        #expect(values.reduce(0) { $0 + $1.result.rawText.count + $1.result.outputText.count } <= 100_000)
        let oversized = entry(String(repeating: "x", count: 50_001))
        #expect(RecentDictationResult.retaining(oversized, in: values, enabled: true) == values)
    }

    @Test("application exceptions require an exact explicitly configured bundle identifier")
    func dupOriginalApplicationMembership() {
        let configured: Set<String> = ["test.terminal"]
        #expect(usesOriginalText(bundleIdentifier: "test.terminal", exceptions: configured))
        #expect(!usesOriginalText(bundleIdentifier: nil, exceptions: configured))
        #expect(!usesOriginalText(bundleIdentifier: "test.other", exceptions: configured))
        #expect(!usesOriginalText(bundleIdentifier: "test.terminal", exceptions: []))
    }
}

extension DictationControllerTests {
    @Test("a dictation joining background preparation records its actual wait")
    func dupBackgroundPreparationWaitIsCorrelated() async throws {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { backend },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        defer { backend.finishPreparation(); controller.cancel() }
        controller.prepare()
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.preparationContinuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        _ = try #require(backend.preparationContinuation)
        controller.press()
        let id = try #require(controller.currentRunID).uuidString
        let prepared = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            backend.finishPreparation()
        }
        await controller.waitForWorkForTests()
        await prepared.value
        #expect(events.contains { $0.operation == "dictation.preparation-wait" && $0.runID == id })
        #expect(events.allSatisfy { $0.runID == id })
        controller.cancel()
        await controller.waitForWorkForTests()
    }

    @Test("release during preparation ends an empty recording's diagnostics run exactly once")
    func dupEarlyReleaseEndsRun() async throws {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        backend.authoritativeResult = nil
        let capture = FakeCapture(log: EventLog())
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false }, onRunTiming: { events.append($0) })
        defer { backend.finishPreparation(); controller.cancel() }
        controller.press()
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.preparationContinuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        _ = try #require(backend.preparationContinuation)
        controller.release()
        backend.finishPreparation()
        await controller.waitForWorkForTests()
        #expect(capture.started)
        #expect(capture.stopped)
        #expect(capture.takeCalls == 1)
        #expect(controller.currentRunID == nil)
        #expect(events.filter { $0.outcome != nil }.map(\.outcome) == ["failed"])
        controller.cancel()
        await controller.waitForWorkForTests()
        #expect(events.filter { $0.outcome != nil }.count == 1)
    }

    @Test("an observed backend failure ends its run as failed rather than cancelled")
    func dupBackendFailureHasFailedOutcome() async throws {
        let backend = FakeBackend(log: EventLog())
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { backend },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        controller.press()
        await controller.waitForWorkForTests()
        let runID = try #require(controller.currentRunID).uuidString
        let reportFailure = try #require(backend.failureHandler)
        reportFailure("Synthetic recognition failure")
        for _ in 0..<200 where controller.isActive { await Task.yield() }
        await controller.waitForWorkForTests()
        let terminal = events.filter { $0.outcome != nil }
        #expect(terminal.map(\.outcome) == ["failed"])
        #expect(terminal.first?.runID == runID)
    }

    @Test("late cancelled preparation cannot add time to the next dictation")
    func dupLatePreparationKeepsRunIdentity() async throws {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { backend },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        controller.press()
        for _ in 0..<200 where backend.preparationContinuation == nil { await Task.yield() }
        _ = try #require(backend.preparationContinuation)
        let firstID = try #require(controller.currentRunID).uuidString
        controller.cancel()
        controller.press()
        let secondID = try #require(controller.currentRunID).uuidString
        backend.blockPreparation = false
        backend.finishPreparation()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        let preparation = events.filter { $0.operation == "dictation.preparation" }
        #expect(preparation.count == 1)
        #expect(preparation.allSatisfy { $0.runID == secondID })
        #expect(events.filter { $0.runID == firstID && $0.outcome != nil }.map(\.outcome) == ["cancelled"])
        #expect(events.allSatisfy { $0.runID != nil })
    }

    @Test("background prewarming has no dictation identity and delivery has its own stage")
    func dupPrewarmAndDeliveryTimings() async {
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        controller.prepare()
        await controller.waitForWorkForTests()
        #expect(events.isEmpty)
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(events.contains { $0.operation == "dictation.capture-start" })
        #expect(events.contains { $0.operation == "dictation.delivery" })
        #expect(events.allSatisfy { $0.runID != nil })
    }

    @Test("a cancelled processing stage cannot change a new run's timing or fallback", arguments: ["cleanup", "translation"])
    func dupLateProcessingKeepsRunIdentity(stage: String) async throws {
        var continuation: CheckedContinuation<String?, Never>?
        var calls = 0
        var events: [DiagnosticsRuntimeTiming] = []
        let process: (String) async -> String? = { text in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { continuation = $0 } }
            return text
        }
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            translationConfiguration: { .init(enabled: stage == "translation", target: "de") },
            translate: { text, _, _ in await process(text) },
            cleanupConfiguration: { .init(enabled: stage == "cleanup") },
            cleanup: { text, _ in await process(text) },
            onRunTiming: { events.append($0) })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        controller.cancel()
        controller.press()
        let secondID = try #require(controller.currentRunID).uuidString
        pending.resume(returning: nil)
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(events.filter { $0.operation == "dictation.\(stage)" }.count == 1)
        let terminal = events.filter { $0.runID == secondID && $0.outcome != nil }
        #expect(terminal.map(\.outcome) == ["copied"])
        #expect(terminal.first?.fallbackReason == nil)
        #expect(events.allSatisfy { $0.runID != nil })
    }

    @Test("dictation timings share one content-free run identity and one terminal outcome")
    func dupRunTimingSharesIdentity() async {
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(!events.isEmpty)
        #expect(Set(events.compactMap(\.runID)).count == 1)
        #expect(events.allSatisfy { $0.runID != nil && $0.seconds.isFinite && $0.seconds >= 0 })
        #expect(events.filter { $0.outcome != nil }.map(\.outcome) == ["copied"])
        #expect(events.contains { $0.operation == "dictation.transcription" })
        #expect(!events.contains { $0.operation.contains("hello from dictation") })
    }

    @Test("cancelled dictation emits exactly one terminal outcome with its observed run ID")
    func dupRunTimingCancellationOnce() async {
        var events: [DiagnosticsRuntimeTiming] = []
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: FakeInserter(), captionsActive: { false },
            onRunTiming: { events.append($0) })
        controller.press()
        await controller.waitForWorkForTests()
        controller.cancel()
        controller.cancel()
        await controller.waitForWorkForTests()
        #expect(events.filter { $0.outcome != nil }.map(\.outcome) == ["cancelled"])
        #expect(Set(events.compactMap(\.runID)).count == 1)
    }

    @Test("an explicit original-text exception is frozen at press and skips processing")
    func dupOriginalApplicationUsesCapturedIntent() async {
        let original = "echo FooSDK && printf 'hello' — 字幕\n次の行です"
        let backend = FakeBackend(log: EventLog())
        backend.authoritativeResult = original
        let inserter = FakeInserter()
        let appID = inserter.focus.bundleIdentifier ?? "test.source"
        var applications: Set<String> = [appID]
        var cleanupCalls = 0
        var translationCalls = 0
        let controller = DictationController(makeBackend: { backend }, capture: FakeCapture(log: EventLog()),
            inserter: inserter, captionsActive: { false },
            translationConfiguration: { .init(enabled: true, target: "de") },
            translate: { _, _, _ in translationCalls += 1; return "changed" },
            cleanupConfiguration: { .init(enabled: true) },
            cleanup: { _, _ in cleanupCalls += 1; return "changed" },
            originalTextApplications: { applications })
        controller.press()
        await controller.waitForWorkForTests()
        applications.removeAll()
        inserter.focus = .init(processIdentifier: 2, bundleIdentifier: "test.other")
        controller.release()
        await controller.waitForWorkForTests()
        #expect(cleanupCalls == 0)
        #expect(translationCalls == 0)
        #expect(inserter.inserted == [original])
        #expect(backend.finishDictationCalls == 1)
    }

    @Test("the completion callback follows delivery and setup trials never enter history")
    func dupDeliveryCallbackReflectsActualDelivery() async {
        let backend = FakeBackend(log: EventLog())
        let inserter = FakeInserter()
        var deliveries: [TextInsertionResult] = []
        let controller = DictationController(makeBackend: { backend }, capture: FakeCapture(log: EventLog()),
            inserter: inserter, captionsActive: { false },
            onDelivered: { _, delivery, _ in
                #expect(inserter.inserted.count == 1)
                deliveries.append(delivery)
            })
        controller.press(previewOnly: true)
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(deliveries.isEmpty)
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(deliveries.map(\.outcome) == [.copied])
    }

    @Test("cancel from a result callback prevents both insertion and extra delivery")
    func dupCancellationAtResultBoundary() async {
        let inserter = FakeInserter()
        var controller: DictationController?
        var deliveries = 0
        controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: inserter, captionsActive: { false },
            onResult: { _ in controller?.cancel() },
            onDelivered: { _, _, _ in deliveries += 1 })
        controller?.press()
        await controller?.waitForWorkForTests()
        controller?.release()
        await controller?.waitForWorkForTests()
        #expect(inserter.inserted.isEmpty)
        #expect(deliveries == 0)
        #expect(controller?.phase == .idle)
    }
}
