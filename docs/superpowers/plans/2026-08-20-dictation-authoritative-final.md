# Authoritative Dictation Finalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ] ) syntax for tracking.

**Goal:** Make press-to-talk dictation insert the recognizer's authoritative completed utterance, preserve rolling caption behavior, and use conservative Hy-MT2 sampling.

**Architecture:** Add one dictation-specific completion boundary to TranscriptionBackend. The streaming backend stops its pump, calls finishSession() once, returns that complete transcript without sending it through the caption callback, and resets the loaded engine for reuse. DictationController prefers that result and retains its existing final-chunk collector as a compatibility fallback; captions retain their flushPending() plus stop() path through the protocol default.

**Tech Stack:** Swift 6 / Swift Package Manager, AVFoundation, FluidAudio streaming engines, existing LLM wrapper, Swift Testing, release-mode test hooks.

## Global Constraints

- Work in /Users/enrico/Documents/GitHub/saiity on the explicitly approved main checkout; re-read overlapping files immediately before each edit.
- Keep StreamingASRBackend.stop() as the caption finalization path and do not change rolling thresholds or caption callback timing.
- finishDictation() calls the engine's finishSession() at most once per session and never emits its authoritative result as a caption final.
- Dictation prefers non-empty authoritative text and falls back to collected rolling finals when unavailable or empty.
- Loaded ASR resources remain reusable after dictation completion; only release() tears them down.
- Keep whole-sentence translation and MADLAD's recommendation unchanged.
- Preserve swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS.
- Do not change microphone lifecycle, insertion behavior, transcript storage, UI, model selection, or release metadata.

## Files and Responsibilities

- Sources/sAiity/TranscriptionBackend.swift: completion API and compatibility fallback.
- Sources/sAiity/StreamingASRBackend.swift: authoritative completion and shared teardown.
- Sources/sAiity/DictationController.swift: completion selection and cancellation guard.
- Sources/sAiity/HyMT2Translator.swift: first and retry temperatures.
- Tests/sAiityTests/DictationControllerTests.swift: early-hypothesis regression and fallback.
- Tests/sAiityTests/StreamingASRBackendTests.swift: dictation completion, caption stop, and reuse.
- Tests/sAiityTests/HyMT2TranslationTests.swift: sampling contract.

---

### Task 1: Add the protocol and controller behavior

**Files:** Modify Sources/sAiity/TranscriptionBackend.swift and Sources/sAiity/DictationController.swift; test Tests/sAiityTests/DictationControllerTests.swift.

**Interfaces:** Add func finishDictation() async -> String?. The protocol default calls flushPending(), then stop(), and returns nil. The controller calls it once and chooses its trimmed non-empty result before the collector.

- [ ] **Step 1: Write the failing regression test.** Extend FakeBackend with:

~~~swift
var authoritativeResult: String?
var finishDictationCalls = 0

func finishDictation() async -> String? {
    finishDictationCalls += 1
    if let authoritativeResult {
        log.values.append("backend.finishDictation")
        return authoritativeResult
    }
    await flushPending()
    await stop()
    return nil
}
~~~

Add:

~~~swift
@Test("dictation inserts the authoritative completion instead of an early rolling final")
func authoritativeCompletionReplacesEarlyHypothesis() async {
    let log = EventLog()
    let backend = FakeBackend(log: log)
    backend.authoritativeResult = "Schedule a meeting with Sarah."
    let inserter = FakeInserter()
    let controller = DictationController(
        makeBackend: { backend }, capture: FakeCapture(log: log),
        inserter: inserter, captionsActive: { false })

    controller.press()
    await controller.waitForWorkForTests()
    backend.onChunk?(TranscriptChunk(
        text: "Schedule a meeting with Sara", isFinal: true))
    controller.release()
    await controller.waitForWorkForTests()

    #expect(backend.finishDictationCalls == 1)
    #expect(log.values == ["backend.finishDictation"])
    #expect(inserter.inserted == ["Schedule a meeting with Sarah."])
}
~~~

- [ ] **Step 2: Verify RED.** Run:

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests/authoritativeCompletionReplacesEarlyHypothesis
~~~

Expected: failure because the current controller calls flushPending() and stop(), so the authoritative method is not used and the early Sara text is inserted.

- [ ] **Step 3: Implement the smallest API and controller change.** Add this protocol requirement and extension implementation:

~~~swift
func finishDictation() async -> String?

extension TranscriptionBackend {
    func finishDictation() async -> String? {
        await flushPending()
        await stop()
        return nil
    }
}
~~~

In DictationController.finish(session:), replace the direct flush/stop pair with:

~~~swift
let authoritative = await backend.finishDictation()
guard session == generation else { return }
self.backend = nil
let authoritativeText = authoritative?.trimmingCharacters(in: .whitespacesAndNewlines)
let text = authoritativeText.flatMap { $0.isEmpty ? nil : $0 } ?? collector.text
~~~

Leave source-language lookup, translation, insertion, and empty-result handling unchanged.

- [ ] **Step 4: Verify GREEN.** Run:

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests
~~~

Expected: the new regression and existing fallback/translation/cancellation/reuse tests pass.

- [ ] **Step 5: Commit.**

~~~bash
git add Sources/sAiity/TranscriptionBackend.swift Sources/sAiity/DictationController.swift Tests/sAiityTests/DictationControllerTests.swift
git commit -m "feat: finalize dictation with authoritative transcript"
~~~

### Task 2: Implement the streaming backend path

**Files:** Modify Sources/sAiity/StreamingASRBackend.swift; test Tests/sAiityTests/StreamingASRBackendTests.swift.

**Interfaces:** StreamingASRBackend.finishDictation() returns the exact engine completion without callback emission. stop() still emits only the uncommitted suffix. Both reset session state but keep loaded model resources.

- [ ] **Step 1: Write the failing backend tests.** Extend FakeEngine with finishResult, finishCalls, a stored partial callback, and:

~~~swift
func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
    partial = callback
}

func finishSession() async -> String? {
    finishCalls += 1
    return finishResult
}
~~~

Add a test that starts a prepared backend, sets finishResult to Schedule a meeting with Sarah., calls finishDictation(), and asserts the exact result, finishCalls == 1, no emitted chunks, then starts and finishes again with loads == 1 and finishCalls == 2. Add a second test that sends Already committed. then Already committed. tail through partial, sets the same full result on the engine, calls stop(), and asserts the only emitted final text is tail.

- [ ] **Step 2: Verify RED.** Run:

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter StreamingASRBackendTests
~~~

Expected: the authoritative test fails because the concrete backend has no implementation; the existing stop/reuse test remains a baseline.

- [ ] **Step 3: Share teardown and add the implementation.** Add:

~~~swift
private func stopPumpAndClearPending() async {
    await stopPump()
    pendingLock.withLock {
        pending = []
        overflowing = false
    }
}
~~~

Use it at the start of stop(), then add:

~~~swift
func finishDictation() async -> String? {
    await stopPumpAndClearPending()
    let full = sessionStarted ? await engine.finishSession() : nil
    await engine.reset()
    sessionStarted = false
    emit = nil
    return full
}
~~~

Do not call flushPending() or emit full from this method. Preserve the existing stop() suffix calculation and callback.

- [ ] **Step 4: Verify GREEN.**

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'StreamingASRBackendTests|DictationControllerTests'
~~~

Expected: authoritative completion, caption suffix, engine reuse, and controller tests all pass.

- [ ] **Step 5: Commit.**

~~~bash
git add Sources/sAiity/StreamingASRBackend.swift Tests/sAiityTests/StreamingASRBackendTests.swift
git commit -m "feat: expose authoritative streaming completion for dictation"
~~~

### Task 3: Lower Hy-MT2 sampling temperatures

**Files:** Modify Sources/sAiity/HyMT2Translator.swift; test Tests/sAiityTests/HyMT2TranslationTests.swift.

**Interfaces:** Add internal testable constants generationTemperature: Float = 0.1 and retryTemperature: Float = 0.15; use them for initial and validator-retry generation respectively. Keep topK, topP, repeat penalty, token limit, prompt, validator, and model recommendation unchanged.

- [ ] **Step 1: Write the failing contract test.**

~~~swift
@Test("Hy-MT2 uses conservative first-pass and retry sampling")
func samplingTemperaturesStayQualityFirst() {
    #expect(HyMT2Translator.generationTemperature == Float(0.1))
    #expect(HyMT2Translator.retryTemperature == Float(0.15))
}
~~~

- [ ] **Step 2: Verify RED.** Run:

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter HyMT2TranslationTests/samplingTemperaturesStayQualityFirst
~~~

Expected: compile failure because the constants do not exist.

- [ ] **Step 3: Implement and use the constants.** Set the LLM initializer temperature to Self.generationTemperature, make generate default to that constant, and pass Self.retryTemperature to the retry call.

- [ ] **Step 4: Verify GREEN and commit.**

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter HyMT2TranslationTests
git add Sources/sAiity/HyMT2Translator.swift Tests/sAiityTests/HyMT2TranslationTests.swift
git commit -m "fix: make Hy-MT2 sampling deterministic"
~~~

### Task 4: Full verification and review

- [ ] **Step 1: Run focused tests.**

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'DictationControllerTests|StreamingASRBackendTests|HyMT2TranslationTests'
~~~

- [ ] **Step 2: Run the complete release suite.**

~~~bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
~~~

Expected: exit 0 and zero failures. Existing compiler warnings must be reported separately.

- [ ] **Step 3: Inspect scope and status.**

~~~bash
git diff HEAD~3..HEAD --stat
git status --short --branch
git log -5 --oneline --decorate
~~~

Confirm only the listed source/tests and approved docs changed; no UI, microphone, transcript-store, or release files changed.

- [ ] **Step 4: Review before push or release.** Review the committed range against the approved spec, fix Critical or Important findings, and rerun the complete release suite. This plan does not push or cut a release.

