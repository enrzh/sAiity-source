// Draft outside compiler inputs. MAIN stages this only after the current freeze.
// All native calls below are injected fakes; no weights, recordings or inference.
import AVFoundation
import CTranscribe
import Foundation
import Testing

@testable import sAiity

extension GraniteNativeTests {
    @Test("only the official Granite path binds production load health")
    func modelHealthIdentityDoesNotLabelArbitraryFiles() throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["CODEX_TASK_TMP"])
        let directory = URL(fileURLWithPath: scratch)
        let probe = GraniteNativeProbe()
        let official = GraniteASRBackend(modelURL: ASREngine.graniteURL, artifactDirectory: directory, native: probe.native)
        let synthetic = GraniteASRBackend(modelURL: directory.appendingPathComponent("not-official-\(UUID().uuidString).gguf"),
            artifactDirectory: directory, native: probe.native)
        #expect(official.modelAssetID == AssetID.granite)
        #expect(synthetic.modelAssetID == nil)
        #expect(probe.events.isEmpty) // Identity inspection must not enter any fake/native loader.
    }
}

@Suite(.serialized) struct GraniteNativeTests {
    private func fixture() throws -> URL {
        let scratch = try #require(ProcessInfo.processInfo.environment["CODEX_TASK_TMP"])
        let directory = URL(fileURLWithPath: scratch).appendingPathComponent("granite-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = directory.appendingPathComponent("synthetic.gguf")
        try Data("not model weights".utf8).write(to: model)
        return model
    }

    private func buffer(_ samples: [Float], rate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) { samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![channel].update(from: source.baseAddress!, count: source.count)
        } }
        return buffer
    }

    private func wait(_ probe: GraniteNativeProbe, for event: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !probe.events.contains(event) {
            try #require(ContinuousClock.now < deadline, "missing event: \(event)")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("English locales only; prepared format is 16 kHz mono Float32 and language is not detected")
    func englishOfflineConstraints() async throws {
        let model = try fixture()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        for locale in ["de-DE", "fr", "auto", "und"] {
            let requested = Locale(identifier: locale)
            let probe = GraniteNativeProbe()
            let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
            do { try await backend.prepare(locale: requested, progress: { _ in }); Issue.record("unsupported locale accepted") }
            catch { #expect(error as? GraniteASRBackend.Failure == .unsupportedLocale(requested.identifier)) }
            #expect(!probe.events.contains("load-model"))
        }
        for locale in ["en", "en-US", "en_GB"] {
            let probe = GraniteNativeProbe()
            let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
            #expect(await backend.inputFormat == nil)
            try await backend.prepare(locale: Locale(identifier: locale), progress: { _ in })
            let format = try #require(await backend.inputFormat)
            #expect(format.sampleRate == 16_000 && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32)
            #expect(await backend.detectedLanguage() == nil)
            await backend.release()
        }
    }

    @Test("ABI version, packaged header hash and native layouts are checked before any struct init/load")
    func abiAdmission() async throws {
        let model = try fixture()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        for fault in ["version", "hash", "layout", "unknown-layout"] {
            let probe = GraniteNativeProbe()
            if fault == "version" { probe.version = "0.4.1" }
            if fault == "hash" { probe.headerHash = "0000000000000000" }
            if fault == "layout" { probe.runSize = 96 }
            if fault == "unknown-layout" { probe.runSize = 0 }
            let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
            do { try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in }); Issue.record("ABI mismatch accepted") }
            catch { #expect(error as? GraniteASRBackend.Failure == .incompatibleABI) }
            #expect(!probe.events.contains("init-load") && !probe.events.contains("load-model"))
        }
    }

    @Test("Missing files, native load/session errors and OK with nil handles never become ready")
    func failedPrepareOwnsNoLeakedHandles() async throws {
        let model = try fixture()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        for fault in ["missing", "corrupt", "session", "nil-model", "nil-session", "backend-init"] {
            let probe = GraniteNativeProbe()
            if fault == "corrupt" { probe.loadStatus = TRANSCRIBE_ERR_GGUF }
            if fault == "session" { probe.sessionStatus = TRANSCRIBE_ERR_OOM }
            if fault == "nil-model" { probe.nilModel = true }
            if fault == "nil-session" { probe.nilSession = true }
            if fault == "backend-init" { probe.backendStatus = TRANSCRIBE_ERR_BACKEND }
            let backend = GraniteASRBackend(modelURL: fault == "missing" ? model.appendingPathExtension("missing") : model,
                                           artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
            do { try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in }); Issue.record("failed load accepted") }
            catch { #expect(error as? GraniteASRBackend.Failure != .implementationHeld) }
            #expect(await backend.inputFormat == nil)
            if fault == "missing" { #expect(!probe.events.contains("load-model")) }
            if fault == "session" || fault == "nil-session" { #expect(probe.events.filter { $0 == "free-model" }.count == 1) }
            await backend.release()
            #expect(probe.events.filter { $0 == "free-session" }.isEmpty)
        }
    }

    @Test("NC/other architectures, missing Apache license and incompatible capabilities reject and free model")
    func exactCommercialIdentity() async throws {
        let model = try fixture()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        for fault in ["nc", "arch", "license", "rate", "languages", "streaming", "timestamps", "cancel"] {
            let probe = GraniteNativeProbe()
            if fault == "nc" { probe.info.variant += "-nc" }
            if fault == "arch" { probe.info.architecture = "granite" }
            if fault == "license" { probe.info.license = "cc-by-nc-sa-4.0" }
            if fault == "rate" { probe.info.sampleRate = 48_000 }
            if fault == "languages" { probe.info.languages = ["de"] }
            if fault == "streaming" { probe.info.streaming = true }
            if fault == "timestamps" { probe.info.timestamps = true }
            if fault == "cancel" { probe.info.cancellation = false }
            let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
            do { try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in }); Issue.record("wrong model accepted") }
            catch { #expect(error as? GraniteASRBackend.Failure == .invalidModelIdentity) }
            #expect(!probe.events.contains("make-session"))
            #expect(probe.events.filter { $0 == "free-model" }.count == 1)
        }
    }

    @Test("C sample counts fit int; requested global region subsets reject internal gaps, duplicates, bad order and invalid bounds")
    func sampleAndRegionAdmission() async throws {
        #expect(try GraniteASRBackend.nativeSampleCount(Int(Int32.max)) == Int32.max)
        for count in [0, -1, Int(Int32.max) + 1] {
            #expect(throws: GraniteASRBackend.Failure.self) { try GraniteASRBackend.nativeSampleCount(count) }
        }
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        let invalidSamples: [[Float]] = [[.nan], [.infinity], [1.1], [-1.1]]
        for samples in invalidSamples {
            await #expect(throws: GraniteASRBackend.Failure.self) {
                try await backend.transcribeDictation(samples: samples, regions: [.init(audioRange: 0..<1, coveredRange: 0..<1)])
            }
        }
        let invalidRegions: [[DictationSpeechRegion]] = [
            [.init(audioRange: 0..<3, coveredRange: 0..<3), .init(audioRange: 4..<8, coveredRange: 4..<8)],
            [.init(audioRange: 0..<5, coveredRange: 0..<5), .init(audioRange: 4..<8, coveredRange: 4..<8)],
            [.init(audioRange: 0..<9, coveredRange: 0..<8)],
            [.init(audioRange: 4..<8, coveredRange: 4..<8), .init(audioRange: 0..<4, coveredRange: 0..<4)],
            [.init(audioRange: 2..<4, coveredRange: 2..<4), .init(audioRange: 5..<7, coveredRange: 5..<7)],
            [.init(audioRange: 2..<4, coveredRange: 2..<4), .init(audioRange: 2..<4, coveredRange: 2..<4)],
            [.init(audioRange: 2..<5, coveredRange: 2..<5), .init(audioRange: 4..<7, coveredRange: 4..<7)],
            [.init(audioRange: 4..<6, coveredRange: 4..<6), .init(audioRange: 2..<4, coveredRange: 2..<4)],
            [.init(audioRange: 3..<6, coveredRange: 2..<6)],
            [.init(audioRange: -1..<4, coveredRange: 2..<4)],
            [.init(audioRange: 2..<9, coveredRange: 2..<7)],
            [.init(audioRange: 1..<3, coveredRange: 2..<2)]
        ]
        for regions in invalidRegions {
            await #expect(throws: GraniteASRBackend.Failure.self) {
                try await backend.transcribeDictation(samples: Array(repeating: 0.2, count: 8), regions: regions)
            }
        }
        #expect(probe.inputs.isEmpty)
        #expect(try await backend.transcribeDictation(samples: [], regions: []).text.isEmpty)
        await backend.release()
    }

    @Test("Incremental requests accept stable-prefix, interior and tail subsets against the entire captured array")
    func incrementalGlobalRegionSubsets() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        let samples = (1...16).map { Float($0) / 20 }
        let globalRegions: [DictationSpeechRegion] = [
            .init(audioRange: 0..<5, coveredRange: 0..<4, isForced: true),
            .init(audioRange: 3..<9, coveredRange: 4..<8, isForced: true),
            .init(audioRange: 7..<13, coveredRange: 8..<12, isForced: true),
            .init(audioRange: 11..<16, coveredRange: 12..<16)
        ]
        probe.replies = ["prefix one", "prefix two", "interior", "tail"]
        // Controller owns the full partition across these calls. Each call
        // supplies the same complete array and only the regions requested now.
        let prefix = try await backend.transcribeDictation(samples: samples, regions: Array(globalRegions[0..<2]))
        #expect(prefix.text == "prefix one prefix two")
        #expect(probe.inputs == [Array(samples[0..<5]), Array(samples[3..<9])])
        let interior = try await backend.transcribeDictation(samples: samples, regions: [globalRegions[2]])
        #expect(interior.text == "interior")
        let tail = try await backend.transcribeDictation(samples: samples, regions: [globalRegions[3]])
        #expect(tail.text == "tail")
        #expect(probe.inputs == globalRegions.map { Array(samples[$0.audioRange]) })
        await backend.release()
    }

    @Test("Every region receives exact source audio including the hard-cut overlap; no interim output or invented language/tokens")
    func exactRegionAudioAndOwnedOutput() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        try await backend.start { _ in probe.event("unexpected-chunk") }
        probe.replies = ["Very good. Very good.", "Keep café 42, not 43."]
        let samples = (1...8).map { Float($0) / 10 }
        let result = try await backend.transcribeDictation(samples: samples, regions: [
            .init(audioRange: 0..<5, coveredRange: 0..<4, isForced: true),
            .init(audioRange: 3..<8, coveredRange: 4..<8)
        ])
        #expect(probe.inputs == [Array(samples[0..<5]), Array(samples[3..<8])])
        #expect(result.text.contains("Very good. Very good.") && result.text.contains("café 42, not 43."))
        #expect(!probe.events.contains("unexpected-chunk"))
        #expect(await backend.detectedLanguage() == nil)
        // A subsequent decode overwrites the borrowed C buffer, never an owned Swift result.
        probe.replies = ["other output"]
        _ = try await backend.transcribeDictation(samples: samples, regions: [.init(audioRange: 0..<8, coveredRange: 0..<8)])
        #expect(result.text.contains("café 42, not 43."))
        #expect(probe.checkedRunParams)
        await backend.release()
    }

    @Test("Run errors never return previous success; result-bearing abort/truncation keep owned recovery only")
    func nativeFailureRecovery() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        let samples = Array(repeating: Float(0.2), count: 128)
        let regions: [DictationSpeechRegion] = [.init(audioRange: 0..<128, coveredRange: 0..<128)]
        for status in [TRANSCRIBE_ERR_INVALID_ARG, TRANSCRIBE_ERR_BACKEND, TRANSCRIBE_ERR_INPUT_TOO_SHORT,
                       TRANSCRIBE_ERR_ABORTED, TRANSCRIBE_ERR_OUTPUT_TRUNCATED, TRANSCRIBE_ERR_OUTPUT_REPETITION] {
            probe.runStatus = status
            probe.replies = ["recovery only, never accepted output"]
            do { _ = try await backend.transcribeDictation(samples: samples, regions: regions); Issue.record("native failure became success") }
            catch {
                let resultBearing = [TRANSCRIBE_ERR_ABORTED, TRANSCRIBE_ERR_OUTPUT_TRUNCATED, TRANSCRIBE_ERR_OUTPUT_REPETITION].contains(status)
                #expect(error as? GraniteASRBackend.Failure == .native(Int32(bitPattern: status.rawValue),
                    partial: resultBearing ? "recovery only, never accepted output" : nil,
                    raw: resultBearing ? "recovery only, never accepted output" : nil))
            }
        }
        probe.runStatus = TRANSCRIBE_OK
        probe.replies = ["fresh successful output"]
        #expect(try await backend.transcribeDictation(samples: samples, regions: regions).text == "fresh successful output")
        await backend.release()
    }

    @Test("Float capture is copied synchronously; drain watermark waits for native return AND final callback", .timeLimit(.minutes(1)))
    func copiedCaptureAndCallbackDrain() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        let callbackExit = DispatchSemaphore(value: 0)
        defer { probe.runExit.signal(); callbackExit.signal() }
        try await backend.start { chunk in
            #expect(chunk.isFinal && chunk.words.isEmpty)
            probe.event("callback-enter")
            callbackExit.wait()
            probe.event("callback-exit")
        }
        let pcm = try buffer(Array(repeating: 0.2, count: 128))
        backend.feed(pcm)
        pcm.floatChannelData![0].initialize(repeating: 0.9, count: 128)
        probe.blockRun = true
        let flush = Task { await backend.flushPending() }
        try await wait(probe, for: "run-enter")
        let drain = Task { probe.event("drain-enter"); await backend.drain(toAudioSample: 128); probe.event("drain-done") }
        try await wait(probe, for: "drain-enter")
        try await Task.sleep(for: .milliseconds(5))
        #expect(!probe.events.contains("drain-done"))
        probe.runExit.signal()
        try await wait(probe, for: "callback-enter")
        try await Task.sleep(for: .milliseconds(5))
        #expect(!probe.events.contains("drain-done"))
        callbackExit.signal()
        await flush.value
        await drain.value
        #expect(probe.inputs == [Array(repeating: 0.2, count: 128)])
        let callbackEnd = try #require(probe.events.firstIndex(of: "callback-exit"))
        let drainEnd = try #require(probe.events.firstIndex(of: "drain-done"))
        #expect(callbackEnd < drainEnd)
        await backend.release()
    }

    @Test("Nil or corrupt UTF-8 output and inconsistent OK result flags cannot become accepted text")
    func malformedNativeOutput() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        for fault in ["null", "utf8", "aborted", "truncated"] {
            probe.nilText = fault == "null"
            probe.invalidUTF8 = fault == "utf8"
            probe.abortedOverride = fault == "aborted" ? true : nil
            probe.truncatedOverride = fault == "truncated" ? true : nil
            do {
                _ = try await backend.transcribeDictation(samples: Array(repeating: 0.2, count: 128),
                    regions: [.init(audioRange: 0..<128, coveredRange: 0..<128)])
                Issue.record("malformed native result became accepted text")
            } catch { #expect(error as? GraniteASRBackend.Failure == .invalidNativeResult) }
        }
        await backend.release()
    }

    @Test("Task cancellation flips callback userdata; release must retain callback/session/model until native exits", .timeLimit(.minutes(1)))
    func cancellationAndReleaseOwnNativeUntilReturn() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        probe.blockRun = true
        defer { probe.runExit.signal() }
        let decode = Task { try await backend.transcribeDictation(samples: Array(repeating: 0.2, count: 128),
            regions: [.init(audioRange: 0..<128, coveredRange: 0..<128)]) }
        try await wait(probe, for: "run-enter")
        decode.cancel()
        let release = Task { await backend.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !probe.abortRequested {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!probe.events.contains("abort-clear") && !probe.events.contains("free-session") && !probe.events.contains("free-model"))
        // Simulates Granite's uninterruptible encoder returning OK after cancellation.
        probe.runExit.signal()
        do { _ = try await decode.value; Issue.record("late cancelled output was accepted") }
        catch { #expect(error is CancellationError) }
        await release.value
        let events = probe.events
        let nativeEnd = try #require(events.firstIndex(of: "run-exit"))
        let callbackClear = try #require(events.firstIndex(of: "abort-clear"))
        let sessionFree = try #require(events.firstIndex(of: "free-session"))
        let modelFree = try #require(events.firstIndex(of: "free-model"))
        #expect(nativeEnd < callbackClear && callbackClear < sessionFree && sessionFree < modelFree)
        #expect(events.filter { $0 == "free-session" }.count == 1 && events.filter { $0 == "free-model" }.count == 1)
        #expect(await backend.inputFormat == nil)
        await backend.release()
        #expect(probe.events.filter { $0 == "free-model" }.count == 1)
    }

    @Test("Invalid capture formats fail once and terminal failure releases drains without treating discarded samples as decoded", .timeLimit(.minutes(1)))
    func invalidCaptureTerminatesDrain() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        backend.setFailureHandler { _ in probe.event("capture-failure") }
        try await backend.start { _ in probe.event("unexpected-chunk") }
        backend.feed(try buffer([0.2], channels: 2))
        backend.feed(try buffer([0.2], rate: 48_000))
        await backend.drain(toAudioSample: 1)
        #expect(probe.events.filter { $0 == "capture-failure" }.count == 1)
        #expect(probe.inputs.isEmpty && !probe.events.contains("unexpected-chunk"))
        await backend.release()
    }

    @Test("Two dictation decodes never overlap and queued cancellation makes no native call", .timeLimit(.minutes(1)))
    func exclusiveDecodeAndCancelledAdmission() async throws {
        let model = try fixture(), probe = GraniteNativeProbe()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        probe.blockRun = true
        defer { probe.runExit.signal() }
        let samples = Array(repeating: Float(0.2), count: 128)
        let regions: [DictationSpeechRegion] = [.init(audioRange: 0..<128, coveredRange: 0..<128)]
        let first = Task { try await backend.transcribeDictation(samples: samples, regions: regions) }
        try await wait(probe, for: "run-enter")
        let cancelled = Task { try await backend.transcribeDictation(samples: samples, regions: regions) }
        cancelled.cancel()
        let next = Task { try await backend.transcribeDictation(samples: samples, regions: regions) }
        probe.blockRun = false
        probe.runExit.signal()
        _ = try await first.value
        do { _ = try await cancelled.value; Issue.record("cancelled queued run accepted") }
        catch { #expect(error is CancellationError) }
        _ = try await next.value
        #expect(probe.inputs.count == 2 && probe.maximumInFlight == 1)
        await backend.release()
    }
}

// Implements the reviewed C seam, with borrowed string storage and an explicit
// native completion latch. Every function is fake; no pointer enters C code.
private final class GraniteNativeProbe: @unchecked Sendable {
    let runExit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedInputs: [[Float]] = []
    private var inFlight = 0
    private var peak = 0
    private var callback: transcribe_abort_callback?
    private var callbackData: UnsafeMutableRawPointer?
    private var text = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
    var version = "0.4.0", headerHash = "98540564cd329b85"
    var runSize = 104
    var backendStatus = TRANSCRIBE_OK, loadStatus = TRANSCRIBE_OK, sessionStatus = TRANSCRIBE_OK, runStatus = TRANSCRIBE_OK
    var nilModel = false, nilSession = false
    var nilText = false, invalidUTF8 = false
    var abortedOverride: Bool?, truncatedOverride: Bool?
    private var blocked = false
    var blockRun: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    var replies = ["synthetic native text"]
    var info = GraniteASRBackend.ModelInfo(architecture: "granite5_ctc", variant: "granite-speech-5.0-470m-turboctc",
        license: "apache-2.0", sampleRate: 16_000, languages: ["en"], streaming: false, translation: false,
        languageDetection: false, timestamps: false, cancellation: true)
    private(set) var checkedRunParams = false
    init() { text.initialize(repeating: 0, count: 1024) }
    deinit { text.deallocate() }
    func event(_ value: String) { lock.withLock { recordedEvents.append(value) } }
    var events: [String] { lock.withLock { recordedEvents } }
    var inputs: [[Float]] { lock.withLock { recordedInputs } }
    var maximumInFlight: Int { lock.withLock { peak } }
    var abortRequested: Bool { lock.withLock { callback?(callbackData) ?? false } }

    var native: GraniteASRBackend.Native {
        .init(version: { self.version }, headerHash: headerHash,
            layout: { which in
                switch which {
                case TRANSCRIBE_ABI_MODEL_LOAD_PARAMS, TRANSCRIBE_ABI_SESSION_PARAMS: return (24, 8)
                case TRANSCRIBE_ABI_RUN_PARAMS: return (self.runSize, 8)
                case TRANSCRIBE_ABI_CAPABILITIES: return (56, 8)
                default: return (0, 0)
                }
            }, initializeBackends: { _ in self.event("init-backends"); return self.backendStatus },
            initializeLoadParams: { p in self.event("init-load"); p.struct_size = 24 },
            initializeSessionParams: { p in p.struct_size = 24 },
            initializeRunParams: { p in p.struct_size = 104 },
            loadModel: { _, params in
                #expect(params.struct_size == 24)
                self.event("load-model")
                return (self.loadStatus, self.loadStatus == TRANSCRIBE_OK && !self.nilModel ? OpaquePointer(bitPattern: 0x100) : nil)
            }, inspectModel: { _ in (TRANSCRIBE_OK, self.info) }, makeSession: { _, params in
                #expect(params.struct_size == 24)
                self.event("make-session")
                return (self.sessionStatus, self.sessionStatus == TRANSCRIBE_OK && !self.nilSession ? OpaquePointer(bitPattern: 0x200) : nil)
            }, setAbort: { _, callback, data in
                self.lock.withLock {
                    #expect(self.inFlight == 0, "abort slot mutated while native still owns session")
                    self.callback = callback; self.callbackData = data
                    self.recordedEvents.append(callback == nil ? "abort-clear" : "abort-install")
                }
            }, run: { _, pcm, params in
                let blocked = self.lock.withLock { () -> Bool in
                    self.recordedInputs.append(Array(pcm)); self.inFlight += 1; self.peak = max(self.peak, self.inFlight)
                    self.recordedEvents.append("run-enter")
                    self.checkedRunParams = params.struct_size == 104 && params.task == TRANSCRIBE_TASK_TRANSCRIBE
                        && params.timestamps == TRANSCRIBE_TIMESTAMPS_NONE && params.target_language == nil
                        && params.vocabulary == nil && params.prompt == nil && params.prefix == nil && params.family == nil
                    return self.blocked
                }
                if blocked { self.runExit.wait() }
                self.lock.withLock {
                    let bytes = Array((self.replies.isEmpty ? "synthetic native text" : self.replies.removeFirst()).utf8CString)
                    if self.invalidUTF8 { self.text[0] = CChar(bitPattern: 255); self.text[1] = 0 }
                    else { bytes.withUnsafeBufferPointer { self.text.update(from: $0.baseAddress!, count: $0.count) } }
                    self.recordedEvents.append("run-exit"); self.inFlight -= 1
                }
                return self.runStatus
            }, fullText: { _ in self.nilText ? nil : UnsafePointer(self.text) }, rawText: { _ in self.nilText ? nil : UnsafePointer(self.text) },
            wasAborted: { _ in self.abortedOverride ?? (self.runStatus == TRANSCRIBE_ERR_ABORTED) },
            wasTruncated: { _ in self.truncatedOverride ?? [TRANSCRIBE_ERR_OUTPUT_TRUNCATED, TRANSCRIBE_ERR_OUTPUT_REPETITION].contains(self.runStatus) },
            freeSession: { _ in #expect(self.lock.withLock { self.inFlight == 0 }); self.event("free-session") },
            freeModel: { _ in #expect(self.lock.withLock { self.inFlight == 0 }); self.event("free-model") })
    }
}
// RED draft only; no behavior changes. MAIN: after releasing the compiler freeze,
// APPEND this file to Tests/sAiityTests/GraniteNativeTests.swift. It deliberately
// reuses that file's private fixture/buffer/wait helpers and GraniteNativeProbe.
// Do not stage it as a separate compiler file or duplicate/alter the frozen probe.
// All C calls remain fake; fixture() requires CODEX_TASK_TMP. No weights/audio.

extension GraniteNativeTests {
    // Callback state crosses the serial native queue and the test task. Keep
    // snapshots under a lock; never race an array append against assertions.
    private final class CaptionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TranscriptChunk] = []
        func append(_ value: TranscriptChunk) { lock.withLock { values.append(value) } }
        var chunks: [TranscriptChunk] { lock.withLock { values } }
        var text: String { DictationTranscriptMerger.merge(chunks.map(\.text)) }
    }

    @Test("A cancelled obsolete gap leaves every PCM sample available to a newer successful drain", .timeLimit(.minutes(1)))
    func cancelledCaptionGapContinuesWithoutAudioLoss() async throws {
        let model = try fixture(), probe = GraniteNativeProbe(), results = CaptionResults()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        var native = probe.native
        let originalRun = native.run
        native.run = { session, pcm, params in
            // Output follows actual PCM presented to the fake, so a tail-only
            // decode cannot magically produce the missing prefix's words.
            var words: [String] = []
            if pcm.contains(0.2) { words.append("prefix words") }
            if pcm.contains(0.4) { words.append("tail words") }
            probe.replies = [words.joined(separator: " ")]
            return originalRun(session, pcm, params)
        }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        backend.setFailureHandler { _ in probe.event("unexpected-failure") }
        try await backend.start { results.append($0) }
        let prefix = Array(repeating: Float(0.2), count: 128)
        let tail = Array(repeating: Float(0.4), count: 128)
        probe.blockRun = true
        defer { probe.runExit.signal() }
        backend.feed(try buffer(prefix))
        let obsoleteGap = Task { await backend.drain(toAudioSample: 128) }
        try await wait(probe, for: "run-enter")
        backend.feed(try buffer(tail))
        obsoleteGap.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !probe.abortRequested {
            try #require(ContinuousClock.now < deadline, "cancel did not reach active native userdata")
            try await Task.sleep(for: .milliseconds(1))
        }
        let newerGap = Task { await backend.drain(toAudioSample: 256); probe.event("newer-drain-done") }
        probe.blockRun = false
        probe.runExit.signal()
        await obsoleteGap.value
        await newerGap.value
        #expect(results.text == "prefix words tail words")
        #expect(!probe.events.contains("unexpected-failure"))
        #expect(probe.maximumInFlight == 1)
        // Both original portions reached C, and accepted final chunks cover the
        // entire clock without jumping over the cancelled prefix. Retrying the
        // prefix or preserving a valid uncommitted result are both permitted.
        #expect(probe.inputs.flatMap { $0 }.filter { $0 == 0.2 }.count >= prefix.count)
        #expect(probe.inputs.flatMap { $0 }.filter { $0 == 0.4 }.count >= tail.count)
        let chunks = results.chunks
        #expect(chunks.allSatisfy { $0.isFinal && $0.words.isEmpty })
        #expect(chunks.first?.start == 0)
        #expect(chunks.last?.end == Double(prefix.count + tail.count) / 16_000)
        for pair in zip(chunks, chunks.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        let inputsBeforeRepeat = probe.inputs.count
        let chunksBeforeRepeat = chunks.count
        await backend.drain(toAudioSample: 256)
        #expect(probe.inputs.count == inputsBeforeRepeat && results.chunks.count == chunksBeforeRepeat)
        await backend.release()
    }

    @Test("Normal caption Stop decodes and emits the pending tail before resetting, while retaining the prepared model", .timeLimit(.minutes(1)))
    func captionStopFlushesPendingTail() async throws {
        let model = try fixture(), probe = GraniteNativeProbe(), results = CaptionResults()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        probe.replies = ["pending final tail"]
        try await backend.start { chunk in results.append(chunk); probe.event("stop-final-callback") }
        let samples = Array(repeating: Float(0.2), count: 128)
        backend.feed(try buffer(samples))
        await backend.stop()
        probe.event("stop-returned")
        #expect(probe.inputs == [samples])
        #expect(results.text == "pending final tail" && results.chunks.count == 1)
        #expect(results.chunks.allSatisfy { $0.isFinal && $0.words.isEmpty })
        let nativeEnd = try #require(probe.events.firstIndex(of: "run-exit"))
        let callback = try #require(probe.events.firstIndex(of: "stop-final-callback"))
        let returned = try #require(probe.events.firstIndex(of: "stop-returned"))
        #expect(nativeEnd < callback && callback < returned)
        #expect(await backend.inputFormat != nil)
        #expect(!probe.events.contains("free-session") && !probe.events.contains("free-model"))
        await backend.stop()
        #expect(results.chunks.count == 1 && probe.inputs.count == 1)
        await backend.release()
        #expect(probe.events.filter { $0 == "free-session" }.count == 1)
        #expect(probe.events.filter { $0 == "free-model" }.count == 1)
    }

    @Test("Stop during blocked flush preserves prefix and tail, waits for native return and final callback, and never frees early", .timeLimit(.minutes(1)))
    func captionStopDuringBlockedFlushDrainsAllFinals() async throws {
        let model = try fixture(), probe = GraniteNativeProbe(), results = CaptionResults()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        var native = probe.native
        let originalRun = native.run
        native.run = { session, pcm, params in
            var words: [String] = []
            if pcm.contains(0.2) { words.append("prefix words") }
            if pcm.contains(0.4) { words.append("tail words") }
            probe.replies = [words.joined(separator: " ")]
            return originalRun(session, pcm, params)
        }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        backend.setFailureHandler { _ in probe.event("unexpected-failure") }
        let callbackExit = DispatchSemaphore(value: 0)
        defer { probe.runExit.signal(); callbackExit.signal() }
        try await backend.start { chunk in
            results.append(chunk)
            probe.event("caption-callback-enter")
            if results.chunks.count == 1 { callbackExit.wait() }
            probe.event("caption-callback-exit")
        }
        let prefix = Array(repeating: Float(0.2), count: 128)
        let tail = Array(repeating: Float(0.4), count: 128)
        backend.feed(try buffer(prefix))
        probe.blockRun = true
        let flush = Task { await backend.flushPending() }
        try await wait(probe, for: "run-enter")
        backend.feed(try buffer(tail))
        let stop = Task { probe.event("stop-enter"); await backend.stop(); probe.event("stop-done") }
        try await wait(probe, for: "stop-enter")
        try await Task.sleep(for: .milliseconds(5))
        #expect(!probe.events.contains("stop-done") && !probe.events.contains("abort-clear"))
        #expect(!probe.events.contains("free-session") && !probe.events.contains("free-model"))
        probe.blockRun = false
        probe.runExit.signal()
        try await wait(probe, for: "caption-callback-enter")
        try await Task.sleep(for: .milliseconds(5))
        #expect(!probe.events.contains("stop-done"))
        callbackExit.signal()
        await flush.value
        await stop.value
        #expect(results.text == "prefix words tail words")
        #expect(!probe.events.contains("unexpected-failure") && probe.maximumInFlight == 1)
        let chunks = results.chunks
        #expect(chunks.first?.start == 0 && chunks.last?.end == Double(prefix.count + tail.count) / 16_000)
        for pair in zip(chunks, chunks.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        let callbackEnd = try #require(probe.events.lastIndex(of: "caption-callback-exit"))
        let stopEnd = try #require(probe.events.firstIndex(of: "stop-done"))
        #expect(callbackEnd < stopEnd)
        #expect(!probe.events.contains("free-model"))
        await backend.release()
        let sessionFree = try #require(probe.events.firstIndex(of: "free-session"))
        let modelFree = try #require(probe.events.firstIndex(of: "free-model"))
        #expect(stopEnd < sessionFree && sessionFree < modelFree)
    }

    @Test("Successfully drained continuous captions keep accepting beyond 960000 total samples", .timeLimit(.minutes(1)))
    func drainedCaptionSessionHasNoDictationLifetimeCap() async throws {
        let model = try fixture(), probe = GraniteNativeProbe(), results = CaptionResults()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        backend.setFailureHandler { _ in probe.event("unexpected-failure") }
        try await backend.start { results.append($0) }
        let batch = Array(repeating: Float(0.2), count: 160_000)
        var accepted = 0
        for _ in 0..<7 {
            backend.feed(try buffer(batch))
            accepted += batch.count
            await backend.drain(toAudioSample: accepted)
        }
        #expect(accepted > DictationAudioSampleLimit.maximumSamples)
        let extra = Array(repeating: Float(0.4), count: 128)
        backend.feed(try buffer(extra))
        accepted += extra.count
        await backend.drain(toAudioSample: accepted)
        #expect(!probe.events.contains("unexpected-failure"))
        #expect(probe.inputs.map(\.count) == Array(repeating: batch.count, count: 7) + [extra.count])
        #expect(results.chunks.count == 8 && probe.maximumInFlight == 1)
        #expect(results.chunks.last?.end == Double(accepted) / 16_000)
        let chunks = results.chunks
        for pair in zip(chunks, chunks.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        await backend.release()
    }

    @Test("Actual pending backlog overflow is one explicit terminal failure, not a silent audio loss", .timeLimit(.minutes(1)))
    func pendingCaptionOverflowStillFailsExplicitly() async throws {
        let model = try fixture(), probe = GraniteNativeProbe(), results = CaptionResults()
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let backend = GraniteASRBackend(modelURL: model, artifactDirectory: model.deletingLastPathComponent(), native: probe.native)
        try await backend.prepare(locale: Locale(identifier: "en"), progress: { _ in })
        backend.setFailureHandler { _ in probe.event("pending-overflow") }
        try await backend.start { results.append($0) }
        // No drain between feeds: this is retained backlog, not elapsed lifetime.
        let full = Array(repeating: Float(0.2), count: DictationAudioSampleLimit.maximumSamples)
        backend.feed(try buffer(full))
        #expect(!probe.events.contains("pending-overflow"))
        backend.feed(try buffer([0.4]))
        backend.feed(try buffer([0.4]))
        await backend.drain(toAudioSample: full.count + 1)
        #expect(probe.events.filter { $0 == "pending-overflow" }.count == 1)
        #expect(probe.inputs.isEmpty && results.chunks.isEmpty)
        await backend.release()
    }

    @Test("The linked packaged runtime reports the pinned version and actual public struct ABI without loading models")
    func linkedRuntimeABI() {
        let native = GraniteASRBackend.Native.linked
        #expect(native.version() == GraniteASRBackend.runtimeVersion)
        for (kind, size, alignment) in [
            (TRANSCRIBE_ABI_MODEL_LOAD_PARAMS, MemoryLayout<transcribe_model_load_params>.size, MemoryLayout<transcribe_model_load_params>.alignment),
            (TRANSCRIBE_ABI_SESSION_PARAMS, MemoryLayout<transcribe_session_params>.size, MemoryLayout<transcribe_session_params>.alignment),
            (TRANSCRIBE_ABI_RUN_PARAMS, MemoryLayout<transcribe_run_params>.size, MemoryLayout<transcribe_run_params>.alignment),
            (TRANSCRIBE_ABI_CAPABILITIES, MemoryLayout<transcribe_capabilities>.size, MemoryLayout<transcribe_capabilities>.alignment)
        ] {
            let actual = native.layout(kind)
            #expect(actual.size == size && actual.alignment == alignment)
        }
    }
}
