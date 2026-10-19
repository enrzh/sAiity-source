import AppKit
import Carbon.HIToolbox
import Observation
import Testing
import WhisperKit

@testable import sAiity

extension SavedTranscriptOperationTests.SettingsWindowTests {
    @Test("Explicit Whisper Settings and prewarm entry reject model removal before preparation")
    func explicitWhisperRespectsRemoval() async throws {
        let session = CaptionSession.shared
        let previous = session.isRemovingModels
        defer { session.setRemovingModels(previous) }
        let app = AppDelegate(), calls = DictationControllerTests.EventLog()
        app.whisperPreparationForTests = { _, _ in await MainActor.run { calls.values.append("prepare") } }
        session.setRemovingModels(true)
        do {
            try await app.prepareSelectedWhisperModelForUse(.base)
            Issue.record("Whisper Settings preparation entered during removal")
        } catch { #expect(error is TranslationEngineError) }
        do {
            try await app.prepareSelectedWhisperModelForUse()
            Issue.record("Whisper prewarm entered during removal")
        } catch { #expect(error is TranslationEngineError) }
        #expect(calls.values.isEmpty)
        session.setRemovingModels(false)
        try await app.prepareSelectedWhisperModelForUse(.base)
        #expect(calls.values == ["prepare"])
    }

    @Test("An admitted Whisper preparation prevents unlink until its actual return")
    func admittedWhisperPreventsUnlink() async throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["CODEX_TASK_TMP"])
        let file = URL(fileURLWithPath: scratch).appendingPathComponent("held-whisper-\(UUID().uuidString)")
        try Data("fake".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = AppDelegate(), gate = DictationControllerTests.ContinuationGate()
        app.whisperPreparationForTests = { _, _ in await gate.wait() }
        let preparing = Task { try await app.prepareSelectedWhisperModelForUse(.base) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.entered)
        let state = AppState()
        let asset = ModelAsset(id: "test.held-whisper", family: .recognition, title: "Synthetic", detail: "",
            recommended: false, licence: nil, advertisedBytes: 4, storage: .file(file, expectedBytes: 4),
            removal: .remove(file), use: .never, install: nil)
        await state.delete(asset, prepareForCleanup: { await app.prepareForModelCleanup() })
        #expect(FileManager.default.fileExists(atPath: file.path) && state.modelError != nil)
        #expect(!CaptionSession.shared.isRemovingModels)
        gate.open()
        try await preparing.value
        await state.delete(asset, prepareForCleanup: { await app.prepareForModelCleanup() })
        #expect(!FileManager.default.fileExists(atPath: file.path) && state.modelError == nil)
    }

    @Test("Downloads and model removal have exclusive actor admission")
    func downloadAdmissionHonorsModelRemoval() async throws {
        let coordinator = DownloadCoordinator()
        let gate = AsyncStream<Void>.makeStream()
        var entered = false
        let download = Task {
            try await coordinator.run("synthetic") {
                await MainActor.run { entered = true }
                for await _ in gate.stream { break }
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        #expect(entered)
        #expect(await !coordinator.beginModelRemoval())
        gate.continuation.yield(())
        gate.continuation.finish()
        try await download.value
        #expect(await coordinator.beginModelRemoval())
        #expect(await !coordinator.beginModelRemoval())
        var calls = 0
        do {
            try await coordinator.run("blocked") { await MainActor.run { calls += 1 } }
            Issue.record("Download was admitted during model removal")
        } catch { #expect(error is TranslationEngineError) }
        #expect(calls == 0)
        await coordinator.endModelRemoval()
        try await coordinator.run("after") { await MainActor.run { calls += 1 } }
        #expect(calls == 1)
    }

    @Test("load health uses the frozen asset, clears only on a real load, and ignores absent files")
    func loadHealthBindsFrozenSyntheticAsset() async throws {
        let defaults = UserDefaults.standard
        let keys = ["customLLMModels", "cleanupModelFile", "qwenModelFile", "assetLoadFailures"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        let model = LocalModel(source: .importedFile, file: "gemma-health-\(UUID().uuidString).gguf",
            label: "Synthetic cleanup fixture", bytes: 4, recommended: false, note: "", licence: "test")
        let id = AssetID.llm(file: model.file) // Frozen before any loader await/selection change.
        try FileManager.default.createDirectory(at: LocalModel.directory, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: model.localURL)
        defer { try? FileManager.default.removeItem(at: model.localURL) }
        LocalModel.custom = LocalModel.custom + [model]
        LocalModel.cleanupSelected = model
        let otherHealth = LoadHealth.all
        var calls = 0
        do {
            let _: Int = try await LocalGeneration.loadModel(assetID: id, {
                calls += 1
                await Task.yield()
                LocalModel.cleanupSelected = nil // An asset selected later must not inherit this failure.
                throw CocoaError(.fileReadCorruptFile)
            }, onTiming: { _ in })
            Issue.record("synthetic loader failure became success")
        } catch { #expect(error is CocoaError) }
        #expect(calls == 1 && LoadHealth.reason(for: id) != nil)
        #expect(LoadHealth.all.filter { $0.key != id } == otherHealth.filter { $0.key != id })

        LoadHealth.recordFailureIfInstalled(id, reason: "synthetic prior fault")
        for error in [CancellationError() as any Error, URLError(.cancelled),
                      TranslationEngineError.runtimeUnavailable("synthetic resource shortage")] {
            let before = LoadHealth.all
            do {
                let _: Int = try await LocalGeneration.loadModel(assetID: id, { throw error }, onTiming: { _ in })
                Issue.record("throwing loader became success")
            } catch {}
            #expect(LoadHealth.all == before) // No new damage and no clearing of an earlier fault.
        }
        let value = try await LocalGeneration.loadModel(assetID: id, { calls += 1; return 42 }, onTiming: { _ in })
        #expect(value == 42 && calls == 2 && LoadHealth.reason(for: id) == nil)

        try FileManager.default.removeItem(at: model.localURL)
        let beforeMissing = LoadHealth.all
        do {
            let _: Int = try await LocalGeneration.loadModel(assetID: id, { calls += 1; throw CocoaError(.fileReadCorruptFile) },
                onTiming: { _ in })
        } catch {}
        #expect(calls == 3 && LoadHealth.all == beforeMissing) // Not installed, even though loader threw.
    }
}

extension SavedTranscriptOperationTests.SettingsWindowTests {
    @Test("model removal rejects dictation prepare and press, then permits a later press",
          arguments: [false, true])
    func removalAdmissionBlocksDictation(prewarm: Bool) async {
        let previous = CaptionSession.shared.isRemovingModels
        defer { CaptionSession.shared.setRemovingModels(previous) }
        let log = DictationControllerTests.EventLog(), backend = DictationControllerTests.FakeBackend(log: DictationControllerTests.EventLog())
        let capture = DictationControllerTests.FakeCapture(log: log), inserter = DictationControllerTests.FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false }, modelRemovalActive: { CaptionSession.shared.isRemovingModels }, cleanupConfiguration: { .disabled })
        CaptionSession.shared.setRemovingModels(true)
        if prewarm { controller.prepare() } else { controller.press() }
        await controller.waitForWorkForTests()
        #expect(backend.prepares == 0 && backend.starts == 0)
        #expect(capture.startCalls == 0 && inserter.inserted.isEmpty)
        #expect(!controller.isBusy)
        CaptionSession.shared.setRemovingModels(false)
        controller.press()
        await controller.waitForWorkForTests()
        #expect(capture.startCalls == 1 && backend.prepares == 1)
        controller.cancel()
        await controller.waitForWorkForTests()
    }
}

extension SavedTranscriptOperationTests.SettingsWindowTests {
    @Test("Delete refuses a busy runtime before cancellation, release or unlink")
    func deletionRefusesBusyRuntime() async throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["CODEX_TASK_TMP"])
        let file = URL(fileURLWithPath: scratch).appendingPathComponent("busy-model-\(UUID().uuidString).gguf")
        try Data("fake".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = CaptionSession.shared
        let saved = session.releaseModels
        let removing = session.isRemovingModels
        defer { session.releaseModels = saved; session.setRemovingModels(removing) }
        var releases = 0
        session.releaseModels = { releases += 1 }
        let asset = ModelAsset(id: "test.busy", family: .cleanup, title: "Synthetic", detail: "",
            recommended: false, licence: nil, advertisedBytes: 4, storage: .file(file, expectedBytes: 4),
            removal: .remove(file), use: .never, install: nil)
        let state = AppState()
        await state.delete(asset, prepareForCleanup: { false })
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(state.modelError != nil && releases == 0 && !session.isRemovingModels)
    }

    @Test("Forget keeps custom metadata until native release and uses the guarded removal path")
    func forgetWaitsForNativeBeforeMetadata() async throws {
        let defaults = UserDefaults.standard
        let keys = ["customLLMModels", "cleanupModelFile", "qwenModelFile", "assetLoadFailures", "translationEngine", "dictationTranslationEngine"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        let model = LocalModel(source: .importedFile, file: "gemma-forget-\(UUID().uuidString).gguf",
            label: "Synthetic", bytes: 4, recommended: false, note: "", licence: "test")
        try FileManager.default.createDirectory(at: LocalModel.directory, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: model.localURL)
        defer { try? FileManager.default.removeItem(at: model.localURL) }
        LocalModel.custom += [model]
        let state = AppState()
        state.llmModel = model
        let session = CaptionSession.shared
        let saved = session.releaseModels, removing = session.isRemovingModels
        defer { session.releaseModels = saved; session.setRemovingModels(removing) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.yield(()); gate.continuation.finish() }
        var releaseEntered = false, finished = false
        session.releaseModels = {
            releaseEntered = true
            #expect(session.isRemovingModels)
            #expect(LocalModel.custom.contains { $0.file == model.file })
            #expect(state.llmModel?.file == model.file)
            for await _ in gate.stream { break }
        }
        let forget = Task { await state.forgetCustomModel(model); finished = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while !releaseEntered, !finished, ContinuousClock.now < deadline { await Task.yield() }
        #expect(releaseEntered && !finished)
        if releaseEntered { #expect(FileManager.default.fileExists(atPath: model.localURL.path)) }
        gate.continuation.yield(())
        gate.continuation.finish()
        await forget.value
        #expect(state.modelError == nil && !session.isRemovingModels)
        #expect(!LocalModel.custom.contains { $0.file == model.file })
        #expect(state.llmModel == nil && LocalModel.cleanupSelected == nil)
        #expect(!FileManager.default.fileExists(atPath: model.localURL.path))
    }

    @Test("Model cleanup also unloads a retained unselected cleanup model")
    func cleanupQuiescenceReleasesWarmModel() async {
        let app = AppDelegate()
        var stops = 0
        _ = await app.cleanupSessionForTests.cleanup(.init(text: "Send the report, I mean the revised report.", language: "en"), modelKey: "synthetic-old") {
            .init(cleanup: { _, _, _ in "Send the revised report." }, stop: { stops += 1 })
        }
        #expect(stops == 0)
        #expect(await app.prepareForModelCleanup())
        #expect(stops == 1)
        await app.cleanupSessionForTests.invalidate()
    }

    @Test("unselected old warm owner drains before unlink and keeps removal admission closed")
    func oldWarmOwnerDrainsBeforeUnlink() async throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["CODEX_TASK_TMP"])
        let file = URL(fileURLWithPath: scratch)
            .appendingPathComponent("old-warm-\(UUID().uuidString).gguf")
        try Data("fake".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "translationEngine", "dictationTranslationEngine",
                    "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key,
                    "cleanupModelFile", "qwenModelFile", "assetLoadFailures"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let session = CaptionSession.shared
        let previousRelease = session.releaseModels
        let wasRunning = session.isRunning, wasStopping = session.isStopping
        let wasRemoving = session.isRemovingModels
        try #require(!wasRemoving && !session.isProcessingTranscript)
        defer {
            session.releaseModels = previousRelease
            session.setRunning(wasRunning, stopping: wasStopping)
            session.setRemovingModels(wasRemoving)
            for (key, value) in previous { defaults.set(value, forKey: key) }
        }
        session.setRunning(false)
        let state = AppState()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.yield(()); gate.continuation.finish() }
        var releaseEntered = false, releaseFinished = false, deleteFinished = false
        var events: [String] = []
        session.releaseModels = {
            #expect(session.isRemovingModels)
            #expect(FileManager.default.fileExists(atPath: file.path))
            releaseEntered = true
            events.append("release-enter")
            for await _ in gate.stream { break }
            releaseFinished = true
            events.append("release-exit")
        }
        let asset = ModelAsset(id: "test.old-warm.\(UUID().uuidString)", family: .cleanup,
            title: "Synthetic old warm owner", detail: "", recommended: false, licence: nil,
            advertisedBytes: 4, storage: .file(file, expectedBytes: 4),
            removal: .remove(file), use: .never, install: nil,
            unload: {
                MainActor.assumeIsolated {
                    #expect(releaseFinished && session.isRemovingModels)
                    #expect(FileManager.default.fileExists(atPath: file.path))
                    events.append("unlink-boundary")
                }
            })
        let deletion = Task { @MainActor in await state.delete(asset); deleteFinished = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while !releaseEntered, !deleteFinished, ContinuousClock.now < deadline { await Task.yield() }
        #expect(releaseEntered && !deleteFinished)
        if releaseEntered {
            #expect(session.isRemovingModels)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        // Always unblock and await the task, including the expected RED path.
        gate.continuation.yield(())
        gate.continuation.finish()
        await deletion.value
        #expect(events == ["release-enter", "release-exit", "unlink-boundary"])
        #expect(state.modelError == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!session.isRemovingModels)
    }
}

extension SavedTranscriptOperationTests {

@MainActor
@Suite struct SettingsWindowTests {
    private func key(_ type: NSEvent.EventType = .keyDown, code: Int, flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "q", charactersIgnoringModifiers: "q", isARepeat: false,
                                     keyCode: UInt16(code)))
    }

    @Test("caption shortcut capture consumes Command combinations before menu handling")
    func captionShortcutCapturesCommand() throws {
        let view = ShortcutRecorder.RecorderView(frame: .init(x: 0, y: 0, width: 130, height: 28))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.makeFirstResponder(nil); window.orderOut(nil) }
        var captured: Shortcut?
        view.onChange = { captured = $0 }
        #expect(view.accessibilityPerformPress())
        #expect(window.firstResponder === view)
        let event = try key(code: kVK_ANSI_Q, flags: .command, window: window)
        #expect(view.performKeyEquivalent(with: event))
        #expect(captured == Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)))
        #expect(!view.performKeyEquivalent(with: event), "ordinary menus work after capture ends")
    }

    @Test("dictation captures a Command chord and waits for its complete release")
    func dictationShortcutCapturesCommandRelease() throws {
        let view = DictationShortcutRecorder.RecorderView(frame: .init(x: 0, y: 0, width: 170, height: 28))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.makeFirstResponder(nil); window.orderOut(nil) }
        var captured: DictationChord?
        view.onChange = { captured = $0 }
        #expect(view.accessibilityPerformPress())
        view.flagsChanged(with: try key(.flagsChanged, code: kVK_Command, flags: .command, window: window))
        #expect(view.performKeyEquivalent(with: try key(code: kVK_ANSI_Q, flags: .command, window: window)))
        view.keyUp(with: try key(.keyUp, code: kVK_ANSI_Q, flags: .command, window: window))
        #expect(captured == nil)
        view.flagsChanged(with: try key(.flagsChanged, code: kVK_Command, window: window))
        #expect(captured == DictationChord(keyCodes: [UInt16(kVK_Command), UInt16(kVK_ANSI_Q)]))
    }

    @Test("shortcut labels do not intercept clicks on the recorder")
    func shortcutLabelsLeaveFullClickTarget() {
        let views: [NSView] = [ShortcutRecorder.RecorderView(), DictationShortcutRecorder.RecorderView()]
        for view in views {
            view.frame = .init(x: 0, y: 0, width: 170, height: 28)
            view.layoutSubtreeIfNeeded()
            #expect(view.hitTest(.init(x: 85, y: 14)) === view)
        }
    }

    @Test("caption shortcut recording suspends dictation and restores it on focus loss")
    func captionShortcutSuspendsUntilFocusLeaves() {
        let view = ShortcutRecorder.RecorderView(frame: .init(x: 0, y: 0, width: 130, height: 28))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        var notifications: [Bool] = []
        let observer = NotificationCenter.default.addObserver(forName: .saiityDictationShortcutRecordingChanged, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { notifications.append(note.object as? Bool ?? false) }
        }
        defer { NotificationCenter.default.removeObserver(observer); window.makeFirstResponder(nil); window.orderOut(nil) }
        #expect(view.accessibilityPerformPress())
        #expect(notifications == [true])
        window.makeFirstResponder(nil)
        #expect(notifications == [true, false])
    }

    @Test("shortcut recording ends when the settings window loses key focus")
    func shortcutRecordingEndsWhenWindowDeactivates() {
        let views: [NSView] = [ShortcutRecorder.RecorderView(), DictationShortcutRecorder.RecorderView()]
        for view in views {
            view.frame = .init(x: 0, y: 0, width: 170, height: 28)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            var notifications: [Bool] = []
            let observer = NotificationCenter.default.addObserver(forName: .saiityDictationShortcutRecordingChanged, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { notifications.append(note.object as? Bool ?? false) }
            }
            #expect(view.accessibilityPerformPress())
            #expect(notifications == [true])
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(notifications == [true, false], "switching apps must restore global shortcut handlers")
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @Test("dictation shortcut recording can be armed with the keyboard")
    func dictationShortcutKeyboardActivation() throws {
        let view = DictationShortcutRecorder.RecorderView(frame: .init(x: 0, y: 0, width: 170, height: 28))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.makeFirstResponder(nil); window.orderOut(nil) }
        #expect(window.makeFirstResponder(view))
        view.keyDown(with: try key(code: kVK_Space, window: window))
        #expect(view.accessibilityValue() as? String == String(localized: "Press the full chord, then release…"))
        view.keyDown(with: try key(code: kVK_Escape, window: window))
        #expect(view.accessibilityValue() as? String == view.chord.displayString)
    }

    @Test("transcript content is available while summary-language analysis is still pending")
    func transcriptDisplaysBeforeLanguageAnalysis() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let lines = [Segment(i: 0, t0: 0, t1: 1, text: "Synthetic original 日本語", loc: "ja", tr: "Synthetic translation", trLoc: "en", words: nil)]
            let session = try TranscriptStore.saveSession(lines, locale: "ja", translateTo: "en", in: root)
            let (gate, release) = AsyncStream<[String]>.makeStream()
            var entered = false
            var displayed: [Segment] = []
            var analyzed: [String]?
            let loading = Task {
                await TranscriptViewerSheet.load(session: session, analyze: { _ in
                    await MainActor.run { entered = true }
                    for await codes in gate { return codes }
                    return []
                }, content: { displayed = $0; #expect($1 == nil) }, languages: { analyzed = $0 })
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            #expect(entered)
            #expect(displayed.map(\.text) == lines.map(\.text))
            #expect(displayed.map(\.tr) == lines.map(\.tr))
            #expect(analyzed == nil)
            release.yield(["ja"]); release.finish()
            await loading.value
            #expect(analyzed == ["ja"])
        }
    }

    @Test("closing a transcript cancels its detached language analysis")
    func transcriptClosingCancelsLanguageAnalysis() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let session = try TranscriptStore.saveSession([Segment(i: 0, t0: 0, t1: 1, text: "Synthetic test", loc: "en", tr: nil, trLoc: nil, words: nil)], locale: "en", translateTo: nil, in: root)
            let (gate, release) = AsyncStream<[String]>.makeStream()
            var entered = false
            var cancelled = false
            var publishedLanguages = false
            let loading = Task {
                await TranscriptViewerSheet.load(session: session, analyze: { _ in
                    await MainActor.run { entered = true }
                    for await codes in gate { return codes }
                    await MainActor.run { cancelled = Task.isCancelled }
                    return []
                }, content: { _, _ in }, languages: { _ in publishedLanguages = true })
            }
            var deadline = ContinuousClock.now + .seconds(2)
            while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            #expect(entered)
            loading.cancel()
            deadline = ContinuousClock.now + .seconds(2)
            while !cancelled, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            #expect(cancelled)
            #expect(!publishedLanguages)
            release.finish()
            await loading.value
        }
    }

    @Test("synthetic long-transcript timings retain every original and translated line")
    func transcriptResponsivenessTimings() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let lines = (0..<2000).map { Segment(i: $0, t0: Double($0), t1: Double($0 + 1), text: "The project has 42 items. Keep the original facts and the complete sentence. Synthetic line \($0).", loc: "en", tr: "Das Projekt hat 42 Einträge. Synthetische Zeile \($0).", trLoc: "de", words: nil) }
            let session = try TranscriptStore.saveSession(lines, locale: "en", translateTo: "de", in: root)
            for run in 0..<3 {
                let began = ContinuousClock.now
                var ready: Duration = .zero
                await TranscriptViewerSheet.load(session: session, content: { loaded, _ in
                    ready = began.duration(to: .now)
                    #expect(loaded.map(\.text) == lines.map(\.text))
                    #expect(loaded.map(\.tr) == lines.map(\.tr))
                }, languages: { #expect($0 == ["en"]) })
                print("SYLLIVRA_PERF transcript lines=2000 run=\(run) ready=\(ready) total=\(began.duration(to: .now))")
            }
        }
    }

    @Test("search opens the selected transcript at its actual matched segment")
    func dupSearchCarriesSegmentAnchor() {
        let state = AppState()
        let session = SessionRef(id: "synthetic", url: URL(fileURLWithPath: "/tmp/saiity-synthetic-unwritten"),
                                 meta: .init(id: "synthetic", startedAt: Date(), locale: "ja", translateTo: nil))
        state.openTranscript(session, revealing: 47)
        #expect(state.transcriptToOpen?.id == session.id)
        #expect(state.transcriptSegmentToReveal == 47)
    }

    @Test("normal transcript open clears a previous search anchor")
    func dupSearchNormalOpenClearsAnchor() {
        let state = AppState()
        let session = SessionRef(id: "synthetic", url: URL(fileURLWithPath: "/tmp/saiity-synthetic-unwritten"),
                                 meta: .init(id: "synthetic", startedAt: Date(), locale: "en", translateTo: nil))
        state.transcriptSegmentToReveal = 47
        state.openTranscript(session)
        #expect(state.transcriptToOpen?.id == session.id)
        #expect(state.transcriptSegmentToReveal == nil)
    }

    @Test("known model load failures offer repair even when installed bytes remain")
    func installedModelFailureNeedsRepair() throws {
        let state = AppState()
        let asset = try #require(ASREngine.nemotron.assetDescriptors.first)
        let installed = AssetStatus(asset: asset, isInstalled: true, isPartial: false, bytesOnDisk: 100)
        state.loadFailures[asset.id] = nil
        #expect(!state.needsModelRepair(installed))
        state.loadFailures[asset.id] = "Synthetic damaged model"
        #expect(state.needsModelRepair(installed))
        state.loadFailures[asset.id] = nil
        #expect(!state.needsModelRepair(installed))
        #expect(state.needsModelRepair(.init(asset: asset, isInstalled: false, isPartial: true, bytesOnDisk: 50)))
    }

    @Test("cleanup download uses only the still-selected model after success")
    func cleanupDownloadPreservesSelectionIntent() async {
        for success in [false, true] {
            for changed in [false, true] {
                var current = "selected.gguf"
                var enabled = false
                await DictationView.cleanupDownloadAction(file: "selected.gguf", selected: { current }, download: {
                    if changed { current = "other.gguf" }
                    return success
                }, enable: { enabled = true })
                #expect(enabled == (success && !changed))
            }
        }
    }

    @Test("turning cleanup off while downloading does not enable it on completion")
    func cleanupDownloadRespectsOffSelection() async {
        var current: String? = "selected.gguf"
        var enabled = false
        await DictationView.cleanupDownloadAction(file: "selected.gguf", selected: { current }, download: {
            current = nil
            return true
        }, enable: { enabled = true })
        #expect(!enabled)
    }

    @Test("dictation readiness checks its model and microphone before calling it ready")
    func dictationReadinessUsesRealPrerequisites() {
        #expect(GeneralView.dictationStatusLabel(enabled: true, input: true, accessibility: true,
                                              modelReady: false, microphone: .authorized) == String(localized: "Not downloaded yet — see Models."))
        #expect(GeneralView.dictationStatusLabel(enabled: true, input: true, accessibility: true,
                                              modelReady: true, microphone: .denied) == String(localized: "Microphone access needed"))
        #expect(GeneralView.dictationStatusLabel(enabled: true, input: true, accessibility: true,
                                              modelReady: true, microphone: .notDetermined) == String(localized: "Microphone requested on first use"))
    }

    @Test("persist-only settings use existing keys and still invalidate observed bindings")
    func defaultsBackedPreferencesRemainObservable() {
        let defaults = UserDefaults.standard
        let keys = ["captionClickThrough", "announceCaptions", CaptionSpeakerTracker.preferenceKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        let properties: [(String, ReferenceWritableKeyPath<AppState, Bool>)] = [
            ("captionClickThrough", \.captionClickThrough),
            ("announceCaptions", \.announceCaptions),
            (CaptionSpeakerTracker.preferenceKey, \.identifyCaptionSpeakers)
        ]
        for (key, property) in properties {
            defaults.set(false, forKey: key)
            #expect(state[keyPath: property] == false)
            let changed = NSLock()
            var notifications = 0
            withObservationTracking {
                _ = state[keyPath: property]
            } onChange: {
                changed.withLock { notifications += 1 }
            }
            state[keyPath: property] = true
            #expect(defaults.bool(forKey: key))
            #expect(state[keyPath: property])
            #expect(changed.withLock { notifications } == 1)
            state[keyPath: property] = false
        }
    }

    @Test("settings keeps the everyday destinations separate")
    func settingsNavigationIsCompact() {
        #expect(SettingsPane.allCases == [.setup, .dictation, .captions, .library, .transcripts])
        #expect(SettingsPane.setup.windowTitle == "General")
    }

    @Test("interrupted download cleanup preserves completed models")
    func interruptedDownloadCleanupPreservesCompletedModels() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-interrupted-test-\(UUID().uuidString)")
        let partialURL = root.appendingPathComponent("partial", isDirectory: true)
        let completeURL = root.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: partialURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: completeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = ModelAsset(
            id: "test.partial", family: .translation, title: "Partial", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .directory(partialURL, markers: ["weights.bin"]),
            removal: .remove(partialURL), use: .never, install: nil)
        let complete = ModelAsset(
            id: "test.complete", family: .translation, title: "Complete", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .directory(completeURL, markers: ["weights.bin"]),
            removal: .remove(completeURL), use: .never, install: nil)
        try Data(repeating: 1, count: 2048)
            .write(to: partialURL.appendingPathComponent("weights.part"))
        try Data(repeating: 2, count: 16)
            .write(to: completeURL.appendingPathComponent("weights.bin"))

        let state = AppState()
        state.assets = [ModelRegistry.status(of: partial), ModelRegistry.status(of: complete)]
        let freed = await state.clearInterruptedDownloads(includeRetired: false)

        #expect(freed == 2048)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(FileManager.default.fileExists(atPath: completeURL.path))
    }

    @Test("download captures model and refreshes readiness")
    func downloadActionUsesCapturedModelAndRefreshesReadiness() async {
        var events: [String] = []
        await DictationView.downloadAction(.base, prepare: { choice in events.append("prepare-\(choice)") }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["prepare-base", "refresh"])
    }

    @Test("download failure stores error and refreshes state")
    func downloadFailureSetsModelErrorAndRefreshesState() async {
        var events: [String] = []
        await DictationView.downloadAction(.small, prepare: { _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"]) }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["error-failed", "refresh"])
    }

    @Test("retry clears failure before using captured model")
    func retryClearsFailureThenUsesCapturedModel() async {
        var events: [String] = []
        await DictationView.retryAction(.small, clearError: { events.append("clear") }, prepare: { choice in events.append("prepare-\(choice)") }, refresh: { events.append("refresh") }, setError: { _ in events.append("error") })
        #expect(events == ["clear", "prepare-small", "refresh"])
    }

    @Test("remove invalidates before deleting and refreshes readiness")
    func removeInvalidatesBeforeDeletingAndRefreshesReadiness() async throws {
        var events: [String] = []
        try await DictationView.removeAction(.base, invalidate: { events.append("invalidate") }, remove: { choice in events.append("remove-\(choice)") }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["invalidate", "remove-base", "refresh"])
    }

    @Test("permission recovery opens input monitoring settings")
    func permissionRecoveryOpensInputMonitoringSettings() {
        var opened: String?
        DictationView.permissionRecoveryAction("Privacy_ListenEvent") { opened = $0 }
        #expect(opened == "Privacy_ListenEvent")
    }

    @Test("not ready action selects existing models pane")
    func notReadyActionSelectsExistingModelsPane() {
        var selected = false
        DictationView.notReadyAction { selected = true }
        #expect(selected)
    }

    @Test("dictation cleanup exposes supported Gemma assets only")
    func dictationCleanupAssetsAreDownloadableAndFamilyRestricted() {
        let statuses = TranslationEngine.qwen.assetDescriptors.map(ModelRegistry.status(of:))
            + TranslationEngine.madlad.assetDescriptors.map(ModelRegistry.status(of:))
        let cleanup = DictationView.cleanupAssets(from: statuses)

        #expect(!cleanup.isEmpty)
        #expect(cleanup.allSatisfy {
            let title = $0.asset.title.lowercased()
            return title.contains("gemma")
        })
        #expect(!cleanup.contains { $0.asset.id == AssetID.madlad })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "gemma-3-1b-it-Q4_K_M.gguf") })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "gemma-3-4b-it-Q4_K_M.gguf") })
        #expect(!cleanup.contains { $0.asset.title.lowercased().contains("qwen") })
    }

    @Test("dictation cleanup is on by default and persists independently")
    func dictationCleanupIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupEnabled", "dictationRecognizer", "asrEngine",
                    "translateTo", "translateDictation", "dictationTranslateTo",
                    "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "dictationRecognizer")
        let state = AppState()
        let cleanupReady = state.llmModel?.isDownloaded == true
        #expect(state.dictationCleanupEnabled == cleanupReady)
        state.dictationCleanupEnabled = false
        #expect(defaults.bool(forKey: "dictationCleanupEnabled") == false)
        state.dictationCleanupEnabled = true
        #expect(state.dictationCleanupEnabled == cleanupReady)
        state.engine = .nemotron
        state.dictationRecognizer = .whisper
        #expect(ASREngine.selected == .nemotron)
        #expect(state.dictationRecognizer == .whisper)
        #expect(WhisperDictationBackend.isSelected)
    }

    @Test("dictation source coverage follows the pinned recognizer vocabulary")
    func dictationLocaleCoversLanguageCatalog() {
        #expect(Set(WhisperDictationBackend.supportedLanguageCodes) == Set(Constants.languageCodes))
        #expect(Set(WhisperDictationBackend.supportedLanguageCodes) != Set(LanguageCatalog.all.map(\.code)))
        #expect(WhisperDictationBackend.ModelChoice.allCases == [.base, .small])
        #expect(WhisperDictationBackend.isReady(.base, under: URL(fileURLWithPath: "/definitely-missing")) == false)
    }

    @Test("dictation recognizer choices update runtime selection without changing captions")
    func dictationRecognizerChoicesAreIndependent() {
        let defaults = UserDefaults.standard
        let snapshot = ["dictationRecognizer", "asrEngine", "dictationStreamingEngine", "whisperDictationSelected",
                        "dictationCleanupEnabled", "translateDictation", "translateTo",
                        CaptionStyle.key].map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "dictationStreamingEngine")
        #expect(ASREngine.dictationSelected == nil)
        #expect(ASREngine.dictationEffective == .nemotron)
        DictationRecognizer.selected = .streaming
        let state = AppState()
        state.dictationRecognizer = .whisper
        WhisperDictationBackend.model = .small
        #expect(DictationRecognizer.selected == .whisper)
        #expect(WhisperDictationBackend.isSelected)
        #expect(WhisperDictationBackend.model == .small)
        #expect(ASREngine.selected != .parakeetEou)
    }

    @Test("dictation profiles map to the existing runtime controls")
    func dictationProfilesApplyWithoutChangingCaptionEngine() {
        let defaults = UserDefaults.standard
        let keys = ["dictationRecognizer", "dictationStreamingEngine", "nemotronChunkMs",
                    "dictationNemotronChunkMs", "asrEngine",
                    "dictationCleanupEnabled", "whisperDictationLocale",
                    "translateTo", "translateDictation", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        defaults.removeObject(forKey: "dictationRecognizer")
        defaults.removeObject(forKey: "dictationStreamingEngine")
        defaults.removeObject(forKey: "nemotronChunkMs")
        defaults.removeObject(forKey: "dictationNemotronChunkMs")
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "whisperDictationLocale")

        let state = AppState()
        let cleanupReady = state.llmModel?.isDownloaded == true
        #expect(state.dictationProfile == (cleanupReady ? DictationProfile.balanced : .custom))

        state.dictationProfile = .fast
        #expect(state.dictationRecognizer == .streaming)
        #expect(defaults.string(forKey: "dictationStreamingEngine") == ASREngine.nemotron.rawValue)
        #expect(state.dictationNemotronTier == 1120)
        #expect(!state.dictationCleanupEnabled)

        state.dictationProfile = .accurate
        #expect(state.dictationRecognizer == .whisper)
        #expect(WhisperDictationBackend.locale == "auto")
        #expect(state.dictationCleanupEnabled == cleanupReady)
        #expect(ASREngine.selected != .parakeetEou)
    }

    @Test("dictation chooses its own recognition model and a preset keeps the choice in sync")
    func dictationModelChoiceIsWritableAndKeptInSync() {
        let defaults = UserDefaults.standard
        let keys = ["dictationRecognizer", "dictationStreamingEngine", "asrEngine",
                    "dictationCleanupEnabled", "dictationNemotronChunkMs", "nemotronChunkMs",
                    "whisperDictationLocale", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        defaults.removeObject(forKey: "dictationStreamingEngine")

        let state = AppState()
        // No choice of its own yet, so it falls back to the recommendation —
        // never to the caption engine, which is a separate preference.
        #expect(state.dictationEngine == nil)

        state.dictationEngine = .qwen17
        #expect(ASREngine.dictationSelected == .qwen17)
        #expect(ASREngine.dictationEffective == .qwen17)
        // Dictation's own key, and the caption one is left alone: this is the
        // separation the profile tests already depend on.
        #expect(defaults.string(forKey: "dictationStreamingEngine") == ASREngine.qwen17.rawValue)
        #expect(ASREngine.selected != .qwen17)

        // A retired value is dropped rather than resurrected, so an old
        // preference cannot come back through the control.
        state.dictationEngine = .whisperTurbo
        #expect(ASREngine.dictationSelected == nil)
        #expect(ASREngine.dictationEffective == .nemotron)
        #expect(defaults.object(forKey: "dictationStreamingEngine") == nil)

        // The failure this control was built to avoid: choosing a preset used
        // to write the key straight to defaults, past the observable, so the
        // picker kept showing the model the user had just moved away from.
        state.dictationEngine = .qwen06
        state.dictationProfile = .fast
        #expect(state.dictationEngine == .nemotron)
        #expect(defaults.string(forKey: "dictationStreamingEngine") == ASREngine.nemotron.rawValue)
    }

    @Test("a dictation profile never touches the caption tier or restarts captions")
    func dictationProfileDoesNotChangeCaptionEngine() {
        let defaults = UserDefaults.standard
        let keys = ["dictationRecognizer", "dictationStreamingEngine", "nemotronChunkMs",
                    "dictationNemotronChunkMs", "asrEngine", "dictationCleanupEnabled",
                    "whisperDictationLocale", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(ASREngine.nemotron.rawValue, forKey: "asrEngine")
        defaults.set(NemotronEngine.chunkMs, forKey: "nemotronChunkMs")
        defaults.removeObject(forKey: "dictationNemotronChunkMs")
        defaults.removeObject(forKey: "dictationRecognizer")
        defaults.removeObject(forKey: "dictationStreamingEngine")
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "whisperDictationLocale")

        var engineChanges = 0
        var dictationChanges = 0
        let state = AppState()
        // Observers go in after construction: `AppState.init` reconciles stored
        // settings and may legitimately post an engine change of its own, which
        // is not what this test is about.
        let engineToken = NotificationCenter.default.addObserver(
            forName: .saiityEngineChanged, object: nil, queue: .main) { _ in
                engineChanges += 1
            }
        let dictationToken = NotificationCenter.default.addObserver(
            forName: .saiityDictationSettingChanged, object: nil, queue: .main) { _ in
                dictationChanges += 1
            }
        defer {
            NotificationCenter.default.removeObserver(engineToken)
            NotificationCenter.default.removeObserver(dictationToken)
        }

        let captionTierBefore = state.nemotronTier
        #expect(captionTierBefore == NemotronEngine.chunkMs)

        // Fast is the profile that used to rewrite the shared caption key.
        state.dictationProfile = .fast
        #expect(state.dictationNemotronTier == 1120)
        #expect(defaults.integer(forKey: "nemotronChunkMs") == captionTierBefore)
        #expect(state.nemotronTier == captionTierBefore)
        #expect(NemotronEngine.selectedChunkMs == captionTierBefore)
        // One dictation refresh, and no engine change at all: an
        // `saiityEngineChanged` here is what stops and rebuilds a live caption
        // session's backend.
        #expect(engineChanges == 0)
        #expect(dictationChanges >= 1)

        state.dictationProfile = .balanced
        #expect(state.dictationNemotronTier == NemotronEngine.chunkMs)
        #expect(state.nemotronTier == captionTierBefore)
        #expect(engineChanges == 0)
    }

    @Test("dictation's tier is its own preference and follows captions only until it chooses")
    func dictationTierIsIndependentOfCaptionTier() {
        let defaults = UserDefaults.standard
        let keys = [NemotronEngine.captionTierKey, NemotronEngine.dictationTierKey]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // Nothing chosen anywhere: both surfaces read the default tier.
        defaults.removeObject(forKey: NemotronEngine.captionTierKey)
        defaults.removeObject(forKey: NemotronEngine.dictationTierKey)
        #expect(NemotronEngine.selectedChunkMs == NemotronEngine.chunkMs)
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)
        #expect(!NemotronEngine.hasExplicitDictationChunkSelection)

        // A caption choice is inherited by dictation, and counts as an explicit
        // pin — exactly the behaviour the shared key used to provide.
        defaults.set(1120, forKey: NemotronEngine.captionTierKey)
        #expect(NemotronEngine.dictationSelectedChunkMs == 1120)
        #expect(NemotronEngine.hasExplicitDictationChunkSelection)

        // Dictation's own choice then wins and the caption tier is left alone.
        NemotronEngine.dictationSelectedChunkMs = NemotronEngine.chunkMs
        #expect(defaults.integer(forKey: NemotronEngine.dictationTierKey) == NemotronEngine.chunkMs)
        #expect(defaults.integer(forKey: NemotronEngine.captionTierKey) == 1120)
        #expect(NemotronEngine.selectedChunkMs == 1120)
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)

        // A tier that is not a real one is refused rather than persisted, so a
        // later read cannot resolve a download against a 404 URL.
        NemotronEngine.dictationSelectedChunkMs = 7
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)
    }

    @Test("a Nemotron tier either surface names counts as in use")
    func nemotronTierInUseCoversBothSurfaces() {
        let defaults = UserDefaults.standard
        let keys = [NemotronEngine.captionTierKey, NemotronEngine.dictationTierKey,
                    "asrEngine", "dictationStreamingEngine", "dictationRecognizer"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(ASREngine.nemotron.rawValue, forKey: "asrEngine")
        defaults.set(NemotronEngine.chunkMs, forKey: NemotronEngine.captionTierKey)
        defaults.set(ASREngine.nemotron.rawValue, forKey: "dictationStreamingEngine")
        defaults.set(DictationRecognizer.streaming.rawValue, forKey: "dictationRecognizer")
        defaults.set(1120, forKey: NemotronEngine.dictationTierKey)

        let inUse = AssetUse.whenNemotronTier(chunkMs: 1120)
        #expect(inUse.isSelected, "the tier dictation runs is not reported as in use")
        // The tier only the caption side names, too.
        #expect(AssetUse.whenNemotronTier(chunkMs: NemotronEngine.chunkMs).isSelected)
        // A third tier that neither names is free to delete.
        #expect(!AssetUse.whenNemotronTier(chunkMs: 480).isSelected)
    }

    @Test("dictation translation is opt-in and persisted")
    func dictationTranslationIsOptIn() {
        let defaults = UserDefaults.standard
        let keys = ["translateDictation", "dictationTranslateTo", "dictationTranslateToMigrated",
                    "asrEngine", "dictationCleanupEnabled", "translateTo", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(true, forKey: "dictationTranslateToMigrated")
        defaults.set("de", forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "translateDictation")
        let state = AppState()
        #expect(state.translateDictation == false)

        state.translateDictation = true
        #expect(defaults.bool(forKey: "translateDictation"))

        state.translateDictation = false
        #expect(defaults.bool(forKey: "translateDictation") == false)
    }

    @Test("a retired dictation engine falls back, and a supported one is honoured")
    func dictationTranslationEngineIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["translationEngine", "dictationTranslationEngine", "asrEngine",
                    "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // The local LLM is still retired, so a stale preference for it must
        // normalize away and leave dictation following the captions choice.
        defaults.set(TranslationEngine.madlad.rawValue, forKey: "translationEngine")
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "dictationTranslationEngine")
        let retired = AppState()
        #expect(retired.dictationTranslationEngine == nil)
        #expect(TranslationEngine.dictationEffective == .madlad)
        // Keep the retired raw value for rollback; the normalized view is what
        // every runtime path consumes.
        #expect(defaults.string(forKey: "dictationTranslationEngine") == TranslationEngine.qwen.rawValue)

        // Hy-MT2 is selectable again, so a dictation preference for it is a
        // real choice rather than a stale one, and it is honoured as written.
        defaults.set(TranslationEngine.hyMT2.rawValue, forKey: "dictationTranslationEngine")
        let supported = AppState()
        #expect(supported.dictationTranslationEngine == .hyMT2)
        #expect(TranslationEngine.dictationEffective == .hyMT2)
    }

    @Test("legacy Qwen translation selections fall back to MADLAD")
    func legacyQwenSelectionDoesNotRemainInVisiblePicker() {
        let defaults = UserDefaults.standard
        let keys = ["translationEngine", "dictationTranslationEngine"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "translationEngine")
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "dictationTranslationEngine")
        #expect(TranslationEngine.visibleSelection(TranslationEngine.selected) == nil)
        #expect(TranslationEngine.effective == .madlad)
        #expect(TranslationEngine.dictationEffective == .madlad)
    }

    @Test("first dictation target initialization inherits captions once, including Off")
    func dictationTargetMigratesOnce() {
        let defaults = UserDefaults.standard
        let keys = ["translateTo", "dictationTranslateTo", "dictationTranslateToMigrated",
                    "asrEngine", "dictationCleanupEnabled", "translateDictation", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set("de", forKey: "translateTo")
        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        let inherited = AppState()
        #expect(inherited.dictationTranslateTo == "de")
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))

        inherited.dictationTranslateTo = "fr"
        inherited.translateTo = "ja"
        let independent = AppState()
        #expect(independent.dictationTranslateTo == "fr")
        #expect(independent.translateTo == "ja")

        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        defaults.removeObject(forKey: "translateTo")
        let off = AppState()
        #expect(off.dictationTranslateTo == nil)
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))
    }

    @Test("dictation language picker has its own presentation state")
    func dictationPickerIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        #expect(state.showTranslationPicker == false)
        #expect(state.showDictationTranslationPicker == false)

        state.showDictationTranslationPicker = true

        #expect(state.showDictationTranslationPicker)
        #expect(state.showTranslationPicker == false)
    }

    @Test("dictation preparation uses its own target when captions are off")
    func dictationPreparationTargetIsIndependent() {
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: nil,
            requestedTarget: "de") == "de")
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: "fr",
            requestedTarget: "de") == "de")
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: "fr",
            requestedTarget: nil) == "fr")
    }

    @Test("dictation picker request selects the Dictation pane")
    func dictationPickerRequestSelectsDictationPane() {
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            settingsWindow()?.close()
            SettingsWindowController.state.showDictationTranslationPicker = false
        }
        SettingsWindowController.showDictationTranslationPicker()

        guard let window = settingsWindow() else {
            Issue.record("settings window was not created")
            return
        }

        #expect(SettingsWindowController.state.showDictationTranslationPicker)
        #expect(SettingsWindowController.selectedPane == .dictation)
        #expect(window.title == SettingsPane.dictation.windowTitle)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(window.contentViewController != nil)
        #expect(abs((window.contentView?.bounds.height ?? 0) - SettingsWindowController.defaultSize.height) < 1)
    }

    @Test("recognition deletion releases dictation's fallback backend")
    func recognitionDeletionReleasesDictationBackendWithoutSelectedEngine() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saiity-delete-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let asset = ModelAsset(
            id: "test-recognition",
            family: .recognition,
            title: "Test recognition",
            detail: "",
            recommended: false,
            licence: nil,
            advertisedBytes: nil,
            storage: .directory(directory, markers: []),
            removal: .remove(directory),
            use: .never,
            install: nil)
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        var released = 0
        let previousRelease = CaptionSession.shared.releaseModels
        let previousRunning = CaptionSession.shared.isRunning
        CaptionSession.shared.releaseModels = { released += 1 }
        CaptionSession.shared.setRunning(false)
        defer {
            CaptionSession.shared.releaseModels = previousRelease
            CaptionSession.shared.setRunning(previousRunning)
        }

        await state.delete(asset)

        #expect(released == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("model inventory refresh completes asynchronously and caches its snapshot")
    func modelInventoryRefreshIsNonBlockingAndCached() async {
        let state = AppState()
        await state.refreshModelsAsync(force: true)
        #expect(!state.assets.isEmpty)
        #expect(!state.isModelsLoading)
        #expect(state.ownedBytes >= 0)
    }

    @Test("settings uses the navigation shell")
    func settingsUsesNavigationShell() {
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            settingsWindow()?.close()
        }
        SettingsWindowController.show()

        guard let window = settingsWindow() else {
            Issue.record("settings window was not created")
            return
        }

        let titles = [SettingsPane.setup, .captions, .dictation, .library, .transcripts].map(\.windowTitle)
        #expect(titles.contains(window.title))
        #expect(SettingsPane.library.windowTitle == "Models")
        #expect(SettingsPane.transcripts.windowTitle == "Transcripts")
        #expect(SettingsWindowController.selectedPane == .dictation || SettingsWindowController.selectedPane == .captions)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.isOpaque)
        #expect(window.toolbar != nil)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(window.contentViewController != nil)
        #expect(window.contentView?.bounds.width ?? 0 >= 760)
        #expect(abs((window.contentView?.bounds.height ?? 0) - SettingsWindowController.defaultSize.height) < 1)
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier == SettingsWindowController.settingsWindowIdentifier
        }
    }
}
}
