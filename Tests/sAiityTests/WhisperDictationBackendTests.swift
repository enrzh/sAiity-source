import Foundation
import Testing
import WhisperKit

@testable import sAiity

@MainActor
@Suite(.serialized)
struct WhisperDictationBackendTests {

    @Test("Whisper decoding failure cannot become an empty or partial successful transcript")
    func nativeDecodeFailureIsNotSilence() {
        let expected = NSError(domain: "WhisperDecodeRegression", code: 7)
        let decoded = TranscriptionResult(text: "The first phrase.", segments: [],
                                          language: "en", timings: .init())
        let fixtures: [[Result<[TranscriptionResult], Error>]] = [
            [.failure(expected)], [.success([decoded]), .failure(expected)]
        ]
        for results in fixtures {
            do {
                _ = try LoadedWhisperDictationModel.transcription(from: results)
                Issue.record("The native decoding error was discarded")
            } catch {
                #expect((error as NSError) === expected)
            }
        }
    }

    @Test("Whisper preserves cancellation instead of returning no speech")
    func nativeDecodeCancellation() {
        #expect(throws: CancellationError.self) {
            try LoadedWhisperDictationModel.transcription(from: [.failure(CancellationError())])
        }
    }

    @Test("Whisper joins successful output in order without rewriting source punctuation")
    func nativeDecodeSuccessfulText() throws {
        let texts = ["That shouldn't happen when you...", "are currently adding items to the card."]
        let results = texts.map {
            Result<[TranscriptionResult], Error>.success([
                .init(text: $0, segments: [], language: "en", timings: .init())
            ])
        }
        let decoded = try LoadedWhisperDictationModel.transcription(from: results)
        #expect(decoded.text == texts.joined(separator: " "))
        #expect(decoded.language == "en")
        #expect(try LoadedWhisperDictationModel.transcription(from: []).text.isEmpty)
    }

    private func makeModel(at root: URL, _ choice: WhisperDictationBackend.ModelChoice = .base) throws {
        let folder = WhisperDictationBackend.modelFolder(for: choice, under: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            let bundle = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
    }

    @Test("normal preparation downloads without constructing or loading Whisper")
    func normalPreparationOnlyDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let backend = WhisperDictationBackend(
            download: { _, destination, _ in
                await events.append("download")
                let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
                    let bundle = folder.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                    try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin"))
                }
                return folder
            },
            prepare: { _, _ in await events.append("setup"); await events.append("load") })

        try await backend.prepareModel(.base, under: root)

        #expect(await events.value == ["download"])
        #expect(!WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("Settings preparation loads before writing the readiness marker")
    func explicitPreparationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let backend = WhisperDictationBackend(download: { _, destination, _ in
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { let bundle = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true); try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin")) }
            await events.append("download"); return folder
        }, prepare: { _, _ in await events.append("setup"); await events.append("load"); await events.append("release") })
        try await backend.prepareModelForUse(.base, under: root)
        await events.append(FileManager.default.fileExists(atPath: WhisperDictationBackend.modelFolder(for: .base, under: root).appendingPathComponent(".saiity-ready").path) ? "marker" : "missing")
        #expect(await events.value == ["download", "setup", "load", "release", "marker"])
        #expect(WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("explicit preparation uses one runtime in setup, load, release, marker order")
    func explicitPreparationUsesOneRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(10))
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { let bundle = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true); try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin")) }
            await events.append("download"); return folder
        }, prepare: { _, _ in await events.append("setup"); await events.append("load"); await events.append("release") })
        try await backend.prepareModelForUse(.base)
        await events.append(FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base/.saiity-ready").path) ? "marker" : "missing")
        #expect(await events.value == ["download", "setup", "load", "release", "marker"])
    }

    @Test("failed explicit preparation removes the final model and marker so a retry fetches fresh bytes")
    func failedPreparationCleansAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Counter()
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            await attempts.increment()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { let bundle = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true); try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin")) }
            return folder
        }, prepare: { _, folder in
            try Data(repeating: 1, count: 1).write(to: folder.appendingPathComponent(".saiity-ready"))
            if await attempts.value == 1 { throw TestError.failed }
        })
        do { try await backend.prepareModelForUse(.base); #expect(Bool(false)) } catch { #expect((error as? TestError) == .failed) }
        // A model that would not load is treated as damaged, and the marker goes
        // with it: `isReady` must not answer from a marker for bytes that are no
        // longer on disk.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-openai_whisper-base").path))
        #expect(!WhisperDictationBackend.isReady(.base, under: root))
        try await backend.prepareModelForUse(.base)
        #expect(await attempts.value == 2)
        #expect(WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("remove deletes folder marker and partial and propagates non-not-found errors")
    func removeModelCleansAllAndPropagatesErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeModel(at: root)
        try Data(repeating: 1, count: 1).write(to: root.appendingPathComponent("whisper-openai_whisper-base/.saiity-ready"))
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
        let called = Flag()
        let backend = WhisperDictationBackend(root: root, transcribe: { _, folder, _, options in
            await called.set(true)
            #expect(folder.path.hasPrefix(root.path))
            #expect(options.language == "en")
            return "ok"
        })
        #expect(try await backend.transcribe(samples: [], locale: Locale(identifier: "en-US")) == "ok")
        #expect(await called.value)
    }

    @Test("unsupported locale rejects before transcription hook")
    func unsupportedLocaleRejectsBeforeHook() async {
        let called = Flag()
        let backend = WhisperDictationBackend(transcribe: { _, _, _, _ in await called.set(true); return "bad" })
        do { _ = try await backend.transcribe(samples: [], locale: Locale(identifier: "xx-YY")); #expect(Bool(false)) } catch { #expect((error as? WhisperDictationError) == .unsupportedLocale("xx-YY")) }
        #expect(!(await called.value))
    }

    /// The defect this exists for: the staging directory was deleted before
    /// every attempt and again on the way out of a cancelled one, so an
    /// interrupted fetch always started from nothing — while the Models page
    /// told the user Resume "continues where it stopped". It resumes into the
    /// same directory, because that is where the downloader keeps both the files
    /// it has finished and the one it was halfway through.
    @Test("a cancelled transfer keeps its staged bytes and the next attempt resumes into them")
    func cancelledTransferKeepsResumeState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = WhisperDictationBackend.stagingDirectory(for: .base, under: root)
        let staged = "models/whisperkit-coreml/openai_whisper-base/AudioEncoder.mlmodelc/weights.bin"
        let attempts = Counter()
        let destinations = Recorder<URL>()
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            await attempts.increment()
            destinations.append(destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Exactly what the Hub downloader leaves behind mid-transfer: a
            // completed file, and the one it was halfway through.
            let finished = destination.appendingPathComponent(staged)
            try FileManager.default.createDirectory(at: finished.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: finished)
            try Data(repeating: 7, count: 512)
                .write(to: destination.appendingPathComponent(staged + ".incomplete"))
            if await attempts.value == 1 { throw CancellationError() }
            let folder = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in WhisperDictationBackend.ModelChoice.requiredBundles {
                let bundle = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin"))
            }
            return folder
        })

        do { try await backend.prepareModel(.base); #expect(Bool(false)) }
        catch { #expect(error is CancellationError) }

        #expect(FileManager.default.fileExists(atPath: staging.path),
                "the staged bytes were thrown away, so Resume starts from nothing")
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(staged).path),
                "a completed file was discarded")
        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent(staged + ".incomplete").path),
            "the half-written file is what lets the next attempt resume mid-file")
        #expect(!WhisperDictationBackend.isDownloaded(.base, under: root),
                "an interrupted transfer reported a model")

        try await backend.prepareModel(.base)
        #expect(await attempts.value == 2)
        // The same directory both times. Two different ones would mean two
        // separate transfers, which is the whole cost this was meant to remove.
        #expect(await destinations.values == [staging, staging])
        #expect(WhisperDictationBackend.isDownloaded(.base, under: root))
        // A successful install reclaims the staging directory; the bytes now
        // live in the model folder, and a leftover copy is a silent leak.
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("whisper-openai_whisper-base.superseded").path))
    }

    /// Everything went right until the last step, and the last step failed:
    /// full disk, a permission change, a cancellation delivered at the move.
    /// The model that was already on disk has to survive that. It used to be
    /// deleted first, so the failure cost the user a working dictation model
    /// *and* the transfer.
    @Test("a transfer that cannot be moved into place leaves the model alone")
    func failedInstallDoesNotDestroyTheInstalledModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = WhisperDictationBackend.modelFolder(for: .base, under: root)
        // Two of the three bundles: incomplete enough that a fetch is still
        // attempted, present enough that destroying it would be a real loss.
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"] {
            let bundle = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 64).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // A path that is not there: the transfer reported success and the
            // folder is gone by the time the move happens — a deleted staging
            // tree, a cleanup racing us, a mount that went away.
            return destination.appendingPathComponent("never-downloaded")
        })

        await #expect(throws: (any Error).self) { try await backend.prepareModel(.base) }

        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"] {
            #expect(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(name).appendingPathComponent("coremldata.bin").path),
                "\(name) was destroyed by a transfer that never landed")
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("whisper-openai_whisper-base.superseded").path),
            "a superseded copy was left behind")
        // And the staged bytes are still there for the next attempt.
        #expect(FileManager.default.fileExists(
            atPath: WhisperDictationBackend.stagingDirectory(for: .base, under: root).path))
    }

    /// The other half: a fetch that does land replaces what was there, in one
    /// step, with nothing left over. A `.superseded` directory that outlived a
    /// successful install is a second copy of a multi-hundred-megabyte model.
    @Test("a completed transfer replaces the old model and leaves no copy behind")
    func successfulInstallReplacesWhatWasThere() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = WhisperDictationBackend.modelFolder(for: .base, under: root)
        let stale = folder.appendingPathComponent("MelSpectrogram.mlmodelc/coremldata.bin")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64).write(to: stale)

        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            let model = destination.appendingPathComponent("downloaded", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            for name in WhisperDictationBackend.ModelChoice.requiredBundles {
                let bundle = model.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data(repeating: 9, count: 512).write(to: bundle.appendingPathComponent("coremldata.bin"))
            }
            return model
        })

        try await backend.prepareModel(.base)
        #expect(WhisperDictationBackend.isDownloaded(.base, under: root))
        // The new bytes, not the old ones: 512, not 64.
        let landed = try Data(contentsOf: folder.appendingPathComponent("MelSpectrogram.mlmodelc/coremldata.bin"))
        #expect(landed.count == 512, "the replaced model kept its old contents")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("whisper-openai_whisper-base.superseded").path))
        #expect(!FileManager.default.fileExists(atPath: WhisperDictationBackend.stagingDirectory(
            for: .base, under: root).path))
    }

    /// Everything the models page's Delete has to take with the model, and the
    /// one thing it must do before it does: let go of the loaded runtime.
    @Test("removal takes the model, its staging, a superseded copy and the damage record")
    func removalTakesEverything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeModel(at: root)
        let staging = WhisperDictationBackend.stagingDirectory(for: .base, under: root)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 128).write(to: staging.appendingPathComponent("half.bin"))
        let superseded = root.appendingPathComponent("whisper-openai_whisper-base.superseded", isDirectory: true)
        try FileManager.default.createDirectory(at: superseded, withIntermediateDirectories: true)

        // Written through the raw key because the recording path is gated on the
        // registry listing the asset as installed, and this test must not need a
        // real model on the developer's disk to prove the record is cleared.
        let key = "assetLoadFailures"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set([AssetID.whisper(.base): "damaged"], forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        #expect(LoadHealth.reason(for: AssetID.whisper(.base)) == "damaged")

        try await WhisperDictationBackend(root: root).removeModel(.base)

        #expect(!FileManager.default.fileExists(atPath: WhisperDictationBackend.modelFolder(
            for: .base, under: root).path))
        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "the staging directory survived the delete")
        #expect(!FileManager.default.fileExists(atPath: superseded.path))
        // A record left behind would badge a model the user has just deleted —
        // or the next one they fetch from the dictation page — as damaged.
        #expect(LoadHealth.reason(for: AssetID.whisper(.base)) == nil)
    }

    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T] = []
        func append(_ value: T) { lock.withLock { storage.append(value) } }
        var values: [T] { lock.withLock { storage } }
    }

    @Test("cancelled preparation keeps the staged bytes for the next attempt")
    func cancelledPreparationKeepsStagedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = WhisperDictationBackend.stagingDirectory(for: .base, under: root)
        let backend = WhisperDictationBackend(root: root, download: { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 32).write(to: destination.appendingPathComponent("half.bin"))
            throw CancellationError()
        })
        do { try await backend.prepareModel(.base); #expect(Bool(false)) } catch { #expect(error is CancellationError) }
        // Kept, because it is the Resume row's content. Cancel is the user
        // changing their mind, not evidence that the bytes are bad.
        #expect(FileManager.default.fileExists(atPath: partial.appendingPathComponent("half.bin").path))
        #expect(!WhisperDictationBackend.isReady(.base, under: root))
    }

    @Test("cancellation preserves an existing final model and marker")
    func cancelledPreparationPreservesReadyModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = WhisperDictationBackend.modelFolder(for: .base, under: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(".saiity-ready")
        try Data(repeating: 1, count: 1).write(to: marker)
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
            for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] { let bundle = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true); try Data(repeating: 1, count: 1).write(to: bundle.appendingPathComponent("coremldata.bin")) }
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

    private actor Flag {
        private(set) var value = false

        func set(_ newValue: Bool) {
            value = newValue
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

    @Test("Whisper source coverage is exactly the pinned recognition vocabulary")
    func sourceCoverageMatchesPinnedVocabulary() {
        #expect(WhisperDictationBackend.supportedLanguageCodes == Constants.languageCodes)
        #expect(!WhisperDictationBackend.supportedLanguageCodes.contains("ig"))
        #expect(WhisperDictationBackend.supportedLanguageCodes.contains("tl"))
        #expect(WhisperDictationBackend.supportedLanguageCodes.contains("jw"))
    }

    @Test("Every pinned Whisper language decodes with its model-native token")
    func everyPinnedSourceCodeDecodes() throws {
        for code in Constants.languageCodes.sorted() {
            let options = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: code))
            #expect(options.language == code, "Whisper token must survive ICU canonicalization: \(code)")
            #expect(options.detectLanguage == false)
        }
    }

    @Test("Source aliases and regional script choices keep Whisper-native language tokens")
    func sourceAliasesKeepNativeTokens() throws {
        for (identifier, expected) in [
            ("fil-PH", "tl"), ("tl-PH", "tl"),
            ("nb-NO", "no"), ("nn-NO", "nn"),
            ("jv-ID", "jw"), ("jw-ID", "jw"),
            ("zh-Hans-CN", "zh"), ("zh-Hant-TW", "zh"),
            ("sr-Latn-RS", "sr"), ("sr-Cyrl-RS", "sr"),
            ("pt-BR", "pt"), ("de_DE", "de")
        ] {
            let options = try WhisperDictationBackend.decodingOptions(for: Locale(identifier: identifier))
            #expect(options.language == expected, "\(identifier) must use \(expected)")
            #expect(options.detectLanguage == false)
        }
    }

    @Test("Translation-only sources are rejected before any transcription work")
    func translationOnlyLocaleDoesNotCallTranscription() {
        #expect(LanguageCatalog.all.contains { $0.code == "ig" })
        var called = false
        #expect(throws: WhisperDictationError.unsupportedLocale("ig-NG")) {
            try WhisperDictationBackend.transcribe(locale: Locale(identifier: "ig-NG")) {
                called = true
            }
        }
        #expect(!called)
    }

    @Test("Every translation catalog entry is checked against Whisper source vocabulary")
    func translationCatalogDoesNotExpandSourceCoverage() throws {
        for language in LanguageCatalog.all {
            let locale = Locale(identifier: language.code)
            let base = locale.identifier(.bcp47).split(separator: "-").first.map(String.init) ?? ""
            let native = ["fil": "tl", "nb": "no", "jv": "jw"][base] ?? base
            if Constants.languageCodes.contains(native) {
                let options = try WhisperDictationBackend.decodingOptions(for: locale)
                #expect(options.language == native, "\(language.code) must use a source token")
                #expect(options.detectLanguage == false)
            } else {
                #expect(throws: WhisperDictationError.unsupportedLocale(locale.identifier)) {
                    try WhisperDictationBackend.decodingOptions(for: locale)
                }
            }
        }
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
