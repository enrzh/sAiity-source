import Foundation
import Testing
import WhisperKit

@testable import sAiity

@MainActor
struct WhisperDictationBackendTests {

    private func makeModel(at root: URL, _ choice: WhisperDictationBackend.ModelChoice = .base) throws {
        let folder = WhisperDictationBackend.modelFolder(for: choice, under: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
    }

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
            prepare: { _, _ in events.append("setup"); events.append("load") })

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
        }, prepare: { _, _ in events.append("setup"); events.append("load"); events.append("release") })
        try await backend.prepareModelForUse(.base, under: root)
        events.append(FileManager.default.fileExists(atPath: WhisperDictationBackend.modelFolder(for: .base, under: root).appendingPathComponent(".saiity-ready").path) ? "marker" : "missing")
        #expect(events == ["download", "setup", "load", "release", "marker"])
        #expect(WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("explicit preparation uses one runtime in setup, load, release, marker order")
    func explicitPreparationUsesOneRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [String] = []
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(10))
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { try Data().write(to: folder.appendingPathComponent(name)) }
            events.append("download"); return folder
        }, prepare: { _, _ in events.append("setup"); events.append("load"); events.append("release") })
        try await backend.prepareModelForUse(.base)
        events.append(FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base/.saiity-ready").path) ? "marker" : "missing")
        #expect(events == ["download", "setup", "load", "release", "marker"])
    }

    @Test("failed explicit preparation removes final model, marker, and partial so retry can succeed")
    func failedPreparationCleansAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            attempts += 1
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { try Data().write(to: folder.appendingPathComponent(name)) }
            return folder
        }, prepare: { _, folder in
            try Data().write(to: folder.appendingPathComponent(".saiity-ready"))
            if attempts == 1 { throw TestError.failed }
        })
        do { try await backend.prepareModelForUse(.base); #expect(Bool(false)) } catch { #expect((error as? TestError) == .failed) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base").path))
        try await backend.prepareModelForUse(.base)
        #expect(attempts == 2)
        #expect(WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("remove deletes folder marker and partial and propagates non-not-found errors")
    func removeModelCleansAllAndPropagatesErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeModel(at: root)
        try Data().write(to: root.appendingPathComponent("whisper-openai_whisper-base/.saiity-ready"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("whisper-openai_whisper-base.partial"), withIntermediateDirectories: true)
        let backend = WhisperDictationBackend(root: root)
        try await backend.removeModel(.base)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base.partial").path))
    }

    @Test("transcription uses the backend root and invokes the hook")
    func transcriptionUsesCustomRootAndHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var called = false
        let backend = WhisperDictationBackend(root: root, transcribe: { _, folder, _, options in
            called = true
            #expect(folder.path.hasPrefix(root.path))
            #expect(options.language == "en")
            return "ok"
        })
        #expect(try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) == "ok")
        #expect(called)
    }

    @Test("unsupported locale rejects before transcription hook")
    func unsupportedLocaleRejectsBeforeHook() async {
        var called = false
        let backend = WhisperDictationBackend(transcribe: { _, _, _, _ in called = true; return "bad" })
        do { _ = try await backend.transcribe(samples: [], locale: Locale(identifier: "xx-YY")); #expect(Bool(false)) } catch { #expect((error as? WhisperDictationError) == .unsupportedLocale("xx-YY")) }
        #expect(!called)
    }

    @Test("cancelled preparation removes only partial state")
    func cancelledPreparationCleansPartial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("whisper-openai_whisper-base.partial")
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            throw CancellationError()
        })
        do { try await backend.prepareModel(.base); #expect(Bool(false)) } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("cancellation preserves an existing final model and marker")
    func cancelledPreparationPreservesReadyModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = WhisperDictationBackend.modelFolder(for: .base, under: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(".saiity-ready")
        try Data().write(to: marker)
        let backend = WhisperDictationBackend(root: root, download: { _, _, _ in
            throw CancellationError()
        })

        do {
            try await backend.prepareModelForUse(.base)
            #expect(Bool(false))
        } catch {
            #expect(error is CancellationError)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("queued cancellation skips the operation and preserves FIFO order")
    func queuedCancellationSkipsOperationAndPreservesFIFO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let calls = Counter()
        let backend = WhisperDictationBackend(root: root, transcribe: { _, _, _, _ in
            await calls.increment()
            let call = await calls.value
            if call == 1 { await gate.wait() }
            return "call-\(call)"
        })
        let first = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        await calls.waitUntilValue(1)
        let second = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        let third = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        second.cancel()
        await gate.open()
        #expect(try await first.value == "call-1")
        do {
            _ = try await second.value
            #expect(Bool(false))
        } catch { #expect(error is CancellationError) }
        #expect(try await third.value == "call-2")
        #expect(await calls.value == 2)
    }

    @Test("cancelling a resumed waiter releases the mutex exactly once")
    func cancellationAfterWaiterResumeReleasesMutex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstGate = Gate()
        let queuedWaiter = Gate()
        let resumedWaiter = Gate()
        let calls = Counter()
        let acquireCount = Counter()
        WhisperDictationBackend.testAfterAcquire = {
            await acquireCount.increment()
            if await acquireCount.value == 2 { await resumedWaiter.open(); await resumedWaiter.waitUntilClosed() }
        }
        WhisperDictationBackend.testAfterEnqueue = { await queuedWaiter.open() }
        defer { WhisperDictationBackend.testAfterAcquire = nil; WhisperDictationBackend.testAfterEnqueue = nil }
        let backend = WhisperDictationBackend(root: root, transcribe: { _, _, _, _ in
            await calls.increment()
            if await calls.value == 1 { await firstGate.wait() }
            return "ok"
        })

        let a = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        await calls.waitUntilValue(1)
        let b = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        let c = Task { try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) }
        await queuedWaiter.waitUntilValue(1)
        await firstGate.open()
        await resumedWaiter.waitUntilValue(1)
        b.cancel()
        await resumedWaiter.close()

        #expect(try await a.value == "ok")
        do { _ = try await b.value; #expect(Bool(false)) } catch { #expect(error is CancellationError) }
        #expect(try await c.value == "ok")
        #expect(await calls.value == 2)
    }

    @Test("cancellation during explicit setup keeps final files and does not write marker")
    func cancellationDuringExplicitSetupPreservesFinalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = WhisperDictationBackend.modelFolder(for: .base, under: root)
        try makeModel(at: root)
        let marker = folder.appendingPathComponent(".saiity-ready")
        let gate = Gate()
        let backend = WhisperDictationBackend(root: root, download: { _, _, _ in
            throw TestError.unexpectedDownload
        }, prepare: { _, _ in await gate.wait() })
        let task = Task { try await backend.prepareModelForUse(.base) }
        await Task.yield()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            #expect(Bool(false))
        } catch { #expect(error is CancellationError) }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("MelSpectrogram.mlmodelc").path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("mixed operations serialize without type casts and preserve typed results", .timeLimit(.minutes(1)))
    func mixedOperationsSerializePerRootAndIdentifier() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let backend = WhisperDictationBackend(
            root: root,
            download: { _, destination, _ in
                await events.append("prepare-start")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try await Task.sleep(for: .milliseconds(20))
                await events.append("prepare-end")
                return destination
            },
            transcribe: { _, _, _, _ in
                await events.append("transcribe")
                return "spoken"
            })

        async let prepare: Void = backend.prepareModel(.base)
        async let transcribe: String = backend.transcribe(samples: [], locale: Locale(identifier: "en-US"))
        let result = try await (prepare, transcribe)

        #expect(result.1 == "spoken")
        try await backend.removeModel(.base)
        let recorded = await events.value
        #expect(recorded == ["prepare-start", "prepare-end", "transcribe"] || recorded == ["transcribe", "prepare-start", "prepare-end"])
    }

    @Test("same model preparation is single-flight while different roots proceed independently", .timeLimit(.minutes(1)))
    func preparationSingleFlightAndRootIsolation() async throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let counter = Counter()
        let backend = WhisperDictationBackend(download: { _, destination, _ in
            await counter.increment()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { try Data().write(to: folder.appendingPathComponent(name)) }
            return folder
        })
        async let a: Void = backend.prepareModel(.base, under: first)
        async let b: Void = backend.prepareModel(.base, under: first)
        async let c: Void = backend.prepareModel(.base, under: second)
        _ = try await (a, b, c)
        #expect(await counter.value == 2)
    }

    private enum TestError: Error, Equatable { case failed, unexpectedDownload }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
        func waitUntilValue(_ expected: Int) async {
            while value < expected { await Task.yield() }
        }
    }

    private actor Gate {
        private var isOpen = false
        func wait() async {
            while !isOpen { await Task.yield() }
        }
        func open() { isOpen = true }
        func close() { isOpen = false }
        func waitUntilValue(_ expected: Int) async { while !isOpen { await Task.yield() } }
        func waitUntilClosed() async { while isOpen { await Task.yield() } }
    }

    private actor EventLog {
        private(set) var value: [String] = []

        func append(_ event: String) {
            value.append(event)
        }
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
