// English-only offline Granite Speech 5.0 TurboCTC. Native work and final
// callbacks share one serial queue; cancellation never frees an active decode.
import AVFoundation
import CTranscribe
import Foundation

final class GraniteASRBackend: TranscriptionBackend, DictationSegmentTranscriber, @unchecked Sendable {
    enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        case implementationHeld
        case unsupportedLocale(String)
        case incompatibleABI
        case missingModel
        case invalidModelIdentity
        case invalidAudio
        case invalidRegions
        case invalidNativeResult
        case native(Int32, partial: String?, raw: String?)

        // Recovery strings are caller-owned data, never diagnostic messages.
        var description: String {
            switch self {
            case .implementationHeld: return String(localized: "Granite implementation is unavailable.")
            case .unsupportedLocale: return String(localized: "Granite recognizes English only.")
            case .incompatibleABI: return String(localized: "Granite native runtime is incompatible with the bundled header.")
            case .missingModel: return String(localized: "The selected Granite model file is missing or empty.")
            case .invalidModelIdentity: return String(localized: "Granite requires the commercial Apache-2.0 English TurboCTC model.")
            case .invalidAudio: return String(localized: "Granite requires bounded 16 kHz mono Float32 audio with finite samples.")
            case .invalidRegions: return String(localized: "Granite speech regions have invalid bounds, order or coverage.")
            case .invalidNativeResult: return String(localized: "Granite returned an invalid or incomplete native result.")
            case .native(let status, _, _):
                return String.localizedStringWithFormat(String(localized: "Granite native operation failed (status %d)."), status)
            }
        }
        var errorDescription: String? { description }
    }

    // Copied model metadata. No borrowed pointer survives inspectModel.
    struct ModelInfo: Sendable {
        var architecture: String
        var variant: String
        var license: String
        var sampleRate: Int
        var languages: [String]
        var streaming: Bool
        var translation: Bool
        var languageDetection: Bool
        var timestamps: Bool
        var cancellation: Bool
    }

    // One C function table, not another model/service layer. Production maps
    // these closures directly to the matched CTranscribe API; tests inject
    // deterministic native return/lifetime conditions without loading weights.
    struct Native: @unchecked Sendable {
        var version: @Sendable () -> String
        var headerHash: String
        var layout: @Sendable (transcribe_abi_struct) -> (size: Int, alignment: Int)
        var initializeBackends: @Sendable (URL) -> transcribe_status
        var initializeLoadParams: @Sendable (inout transcribe_model_load_params) -> Void
        var initializeSessionParams: @Sendable (inout transcribe_session_params) -> Void
        var initializeRunParams: @Sendable (inout transcribe_run_params) -> Void
        var loadModel: @Sendable (URL, transcribe_model_load_params) -> (transcribe_status, OpaquePointer?)
        var inspectModel: @Sendable (OpaquePointer) -> (transcribe_status, ModelInfo)
        var makeSession: @Sendable (OpaquePointer, transcribe_session_params) -> (transcribe_status, OpaquePointer?)
        var setAbort: @Sendable (OpaquePointer, transcribe_abort_callback?, UnsafeMutableRawPointer?) -> Void
        var run: @Sendable (OpaquePointer, UnsafeBufferPointer<Float>, transcribe_run_params) -> transcribe_status
        var fullText: @Sendable (OpaquePointer) -> UnsafePointer<CChar>?
        var rawText: @Sendable (OpaquePointer) -> UnsafePointer<CChar>?
        var wasAborted: @Sendable (OpaquePointer) -> Bool
        var wasTruncated: @Sendable (OpaquePointer) -> Bool
        var freeSession: @Sendable (OpaquePointer) -> Void
        var freeModel: @Sendable (OpaquePointer) -> Void

        // The packaged header/runtime hash is pinned by the distribution. The
        // actual linked version and struct layouts are checked before any init.
        static let linked = Native(
            version: { transcribe_version().flatMap { String(validatingCString: $0) } ?? "" },
            headerHash: GraniteASRBackend.publicHeaderHash,
            layout: { (Int(transcribe_abi_struct_size($0)), Int(transcribe_abi_struct_align($0))) },
            initializeBackends: { directory in
                // Backend discovery is global. Register before loading models;
                // subsequent instances reuse the first registered directory.
                backendLock.withLock {
                    if let backendStatus { return backendStatus }
                    let status = directory.path.withCString { transcribe_init_backends($0) }
                    backendStatus = status
                    return status
                }
            },
            initializeLoadParams: { params in transcribe_model_load_params_init(&params) },
            initializeSessionParams: { params in transcribe_session_params_init(&params) },
            initializeRunParams: { params in transcribe_run_params_init(&params) },
            loadModel: { url, params in
                var params = params
                var handle: OpaquePointer?
                let status = url.path.withCString { transcribe_model_load_file($0, &params, &handle) }
                return (status, handle)
            }, inspectModel: { model in
                var caps = transcribe_capabilities()
                transcribe_capabilities_init(&caps)
                let status = transcribe_model_get_capabilities(model, &caps)
                var info = ModelInfo(architecture: "", variant: "", license: "", sampleRate: 0,
                    languages: [], streaming: false, translation: false, languageDetection: false,
                    timestamps: false, cancellation: false)
                guard status == TRANSCRIBE_OK else { return (status, info) }
                info.architecture = transcribe_model_arch_string(model).flatMap { String(validatingCString: $0) } ?? ""
                info.variant = transcribe_model_variant_string(model).flatMap { String(validatingCString: $0) } ?? ""
                info.license = "general.license".withCString {
                    transcribe_model_meta_val_str(model, $0).flatMap { String(validatingCString: $0) } ?? ""
                }
                info.sampleRate = Int(caps.native_sample_rate)
                if caps.n_languages == 1, let language = caps.languages?[0], let value = String(validatingCString: language) {
                    info.languages = [value]
                }
                info.streaming = caps.supports_streaming
                info.translation = caps.supports_translate
                info.languageDetection = caps.supports_language_detect
                info.timestamps = caps.max_timestamp_kind != TRANSCRIBE_TIMESTAMPS_NONE
                info.cancellation = transcribe_model_supports(model, TRANSCRIBE_FEATURE_CANCELLATION)
                return (status, info)
            }, makeSession: { model, params in
                var params = params
                var handle: OpaquePointer?
                let status = transcribe_session_init(model, &params, &handle)
                return (status, handle)
            }, setAbort: { transcribe_set_abort_callback($0, $1, $2) },
            run: { session, pcm, params in
                guard let count = Int32(exactly: pcm.count), count > 0 else { return TRANSCRIBE_ERR_INVALID_ARG }
                var params = params
                return transcribe_run(session, pcm.baseAddress, count, &params)
            }, fullText: { transcribe_full_text($0) }, rawText: { transcribe_raw_text($0) },
            wasAborted: { transcribe_was_aborted($0) }, wasTruncated: { transcribe_was_truncated($0) },
            freeSession: { transcribe_session_free($0) }, freeModel: { transcribe_model_free($0) })

        private static let backendLock = NSLock()
        private static var backendStatus: transcribe_status?
    }

    /// Userdata is retained by the queued operation until C returns and its
    /// callback is cleared. Granite polls only at entry, not mid-encoder.
    private final class Abort: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline: ContinuousClock.Instant?

        init(deadline: ContinuousClock.Instant?) { self.deadline = deadline }
        func cancel() { lock.withLock { cancelled = true } }
        var requested: Bool { lock.withLock { cancelled } || (deadline.map { ContinuousClock.now >= $0 } ?? false) }
        func check() throws { if requested { throw CancellationError() } }
    }

    static let runtimeVersion = "0.4.0"
    static let publicHeaderHash = "98540564cd329b85"
    static let commercialVariant = "granite-speech-5.0-470m-turboctc"
    let name = "Granite Speech 5.0 470M TurboCTC"
    var modelAssetID: String? {
        modelURL.standardizedFileURL == ASREngine.graniteURL.standardizedFileURL ? AssetID.granite : nil
    }
    private let modelURL: URL
    private let artifactDirectory: URL
    private let native: Native
    private let queue = DispatchQueue(label: "de.aiity.saiity.granite-native", qos: .userInitiated)
    private let lock = NSLock()
    // Native handles and joined capture output are touched only on `queue`.
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var capturedText = ""
    // Capture admission and cancellation must also be reachable synchronously.
    private var format: AVAudioFormat?
    private var pending: [Float] = []
    private var acceptedSamples = 0
    private var completedSamples = 0
    private var epoch = 0
    private var running = false
    private var accepting = false
    private var failed = false
    private var closing = 0
    private var emit: (@Sendable (TranscriptChunk) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?
    private var operations: [UUID: Abort] = [:]

    init(modelURL: URL, artifactDirectory: URL, native: Native = .linked) {
        self.modelURL = modelURL
        self.artifactDirectory = artifactDirectory
        self.native = native
    }

    deinit {
        // Every queued native closure retains self through real completion, so
        // deinit cannot run while a decode/callback still owns these handles.
        if let session { native.freeSession(session) }
        if let model { native.freeModel(model) }
    }

    var inputFormat: AVAudioFormat? { get async { lock.withLock { format } } }

    static func nativeSampleCount(_ count: Int) throws -> Int32 {
        guard let result = Int32(exactly: count), result > 0 else { throw Failure.invalidAudio }
        return result
    }

    func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {
        guard locale.languageCode?.lowercased() == "en" else { throw Failure.unsupportedLocale(locale.identifier) }
        guard modelURL.isFileURL, !modelURL.path.contains("\0"), artifactDirectory.isFileURL,
              !artifactDirectory.path.contains("\0"), FileManager.default.fileExists(atPath: modelURL.path),
              (try? modelURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).map({ $0.isRegularFile == true && ($0.fileSize ?? 0) > 0 }) == true
        else { throw Failure.missingModel }
        try await serialized { abort in
            if self.session != nil { return }
            guard self.native.version() == Self.runtimeVersion, self.native.headerHash == Self.publicHeaderHash else { throw Failure.incompatibleABI }
            for (id, size, alignment) in [
                (TRANSCRIBE_ABI_MODEL_LOAD_PARAMS, MemoryLayout<transcribe_model_load_params>.size, MemoryLayout<transcribe_model_load_params>.alignment),
                (TRANSCRIBE_ABI_SESSION_PARAMS, MemoryLayout<transcribe_session_params>.size, MemoryLayout<transcribe_session_params>.alignment),
                (TRANSCRIBE_ABI_RUN_PARAMS, MemoryLayout<transcribe_run_params>.size, MemoryLayout<transcribe_run_params>.alignment),
                (TRANSCRIBE_ABI_CAPABILITIES, MemoryLayout<transcribe_capabilities>.size, MemoryLayout<transcribe_capabilities>.alignment)
            ] {
                let layout = self.native.layout(id)
                guard layout.size == size, layout.alignment == alignment, layout.size > 0 else { throw Failure.incompatibleABI }
            }
            try Self.check(self.native.initializeBackends(self.artifactDirectory))
            try abort.check()
            progress(String(localized: "Loading Granite Speech…"))
            var params = transcribe_model_load_params()
            self.native.initializeLoadParams(&params)
            let (status, loaded) = self.native.loadModel(self.modelURL, params)
            guard status == TRANSCRIBE_OK else {
                if let loaded { self.native.freeModel(loaded) }
                throw Self.failure(status)
            }
            guard let loaded else { throw Failure.invalidNativeResult }
            var loadedSession: OpaquePointer?
            var installed = false
            defer {
                if !installed {
                    if let loadedSession { self.native.freeSession(loadedSession) }
                    self.native.freeModel(loaded)
                }
            }
            try abort.check()
            let (infoStatus, info) = self.native.inspectModel(loaded)
            try Self.check(infoStatus)
            guard info.architecture == "granite5_ctc", info.variant == Self.commercialVariant,
                  info.license.lowercased() == "apache-2.0", info.sampleRate == 16_000, info.languages == ["en"],
                  !info.streaming, !info.translation, !info.languageDetection, !info.timestamps, info.cancellation
            else { throw Failure.invalidModelIdentity }
            var sessionParams = transcribe_session_params()
            self.native.initializeSessionParams(&sessionParams)
            let created = self.native.makeSession(loaded, sessionParams)
            loadedSession = created.1
            try Self.check(created.0)
            guard let loadedSession else { throw Failure.invalidNativeResult }
            try abort.check()
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
            else { throw Failure.invalidAudio }
            self.model = loaded
            self.session = loadedSession
            self.lock.withLock { self.format = format }
            installed = true
            progress(String(localized: "Granite Speech ready."))
        }
    }

    func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
        try await serialized { _ in
            guard self.session != nil else { throw BackendError.notPrepared }
            self.capturedText = ""
            self.lock.withLock {
                self.epoch += 1
                self.pending.removeAll(keepingCapacity: true)
                self.acceptedSamples = 0
                self.completedSamples = 0
                self.failed = false
                self.running = true
                self.accepting = true
                self.emit = onChunk
            }
        }
    }

    func setFailureHandler(_ handler: (@Sendable (String) -> Void)?) { lock.withLock { failureHandler = handler } }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let currentEpoch = lock.withLock { epoch }
        var invalid = false
        lock.withLock {
            guard accepting, !failed, closing == 0 else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
                  buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
                  count <= DictationAudioSampleLimit.maximumSamples - (acceptedSamples - completedSamples),
                  let channel = buffer.floatChannelData?[0] else { invalid = true; return }
            let samples = UnsafeBufferPointer(start: channel, count: count)
            guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { invalid = true; return }
            // Same synchronous PCM copy used by StreamingASRBackend.feed.
            pending.append(contentsOf: samples)
            acceptedSamples += count
        }
        if invalid { failCapture(Failure.invalidAudio, epoch: currentEpoch) }
    }

    func flushPending() async { await flush(through: nil) }

    func drain(toAudioSample sample: Int) async {
        if sample > 0 { await flush(through: sample) }
        // Even an already-cancelled drain or a concurrent stop must wait for
        // the running native operation AND its callback to leave the queue.
        await fence()
    }

    func finishDictation() async -> String? {
        let currentEpoch = lock.withLock { () -> Int in accepting = false; return epoch }
        do {
            return try await serialized { abort in
                guard self.lock.withLock({ self.running && !self.failed && self.epoch == currentEpoch }) else { return nil }
                _ = try self.flushCaptured(abort: abort, epoch: currentEpoch, through: nil, deliver: false)
                let output = self.capturedText
                self.resetCapture()
                return output.isEmpty ? nil : output
            }
        } catch {
            if !(error is CancellationError) { failCapture(error, epoch: currentEpoch) }
            await fence()
            return nil
        }
    }

    func stop() async { await close(releasing: false) }
    func release() async { await close(releasing: true) }
    func detectedLanguage() async -> String? { nil }

    // `samples` is the entire capture; `regions` is the currently requested
    // continuous subset of global regions. Validate nonempty covered ranges,
    // enclosing/bounded audio ranges, and adjacency/order only within this
    // request. Neither its first covered bound nor its last must span the
    // whole array. The controller owns the complete partition across calls.
    func transcribeDictation(samples: [Float], regions: [DictationSpeechRegion]) async throws -> DictationTranscriptionResult {
        try Task.checkCancellation()
        var previousEnd: Int?
        for region in regions {
            let covered = region.coveredRange, audio = region.audioRange
            guard !covered.isEmpty, covered.lowerBound >= 0, covered.upperBound <= samples.count,
                  !audio.isEmpty, audio.lowerBound >= 0, audio.upperBound <= samples.count,
                  audio.lowerBound <= covered.lowerBound, audio.upperBound >= covered.upperBound,
                  previousEnd.map({ $0 == covered.lowerBound }) ?? true else { throw Failure.invalidRegions }
            _ = try Self.nativeSampleCount(audio.count)
            guard samples[audio].allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw Failure.invalidAudio }
            previousEnd = covered.upperBound
        }
        return try await serialized { abort in
            guard self.session != nil else { throw BackendError.notPrepared }
            // Authoritative regions replace the buffered capture path. Their
            // result must never also enter the live caption callback.
            self.lock.withLock { self.epoch += 1 }
            self.resetCapture()
            var transcripts: [DictationRegionTranscript] = []
            var previousAudioEnd = 0
            for region in regions {
                let text = try self.decode(Array(samples[region.audioRange]), abort: abort)
                transcripts.append(.init(text: text, language: nil,
                    overlapsPreviousAudio: previousAudioEnd > region.audioRange.lowerBound))
                previousAudioEnd = region.audioRange.upperBound
            }
            return DictationTranscriptionResult(regions: transcripts)
        }
    }

    private static func failure(_ status: transcribe_status, partial: String? = nil, raw: String? = nil) -> Failure {
        .native(Int32(bitPattern: status.rawValue), partial: partial, raw: raw)
    }

    private static func check(_ status: transcribe_status) throws {
        if status != TRANSCRIBE_OK { throw failure(status) }
    }

    private func decode(_ samples: [Float], abort: Abort) throws -> String {
        guard let session else { throw BackendError.notPrepared }
        _ = try Self.nativeSampleCount(samples.count)
        try abort.check()
        var params = transcribe_run_params()
        native.initializeRunParams(&params)
        params.task = TRANSCRIBE_TASK_TRANSCRIBE
        params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE
        params.language = nil
        params.target_language = nil
        params.vocabulary = nil
        params.n_vocabulary = 0
        params.prompt = nil
        params.prefix = nil
        params.family = nil
        native.setAbort(session, { context in
            guard let context else { return false }
            return Unmanaged<Abort>.fromOpaque(context).takeUnretainedValue().requested
        }, Unmanaged.passUnretained(abort).toOpaque())
        // Callback mutation and userdata destruction occur only after run has
        // truly returned, including a late OK result after cancellation.
        defer { native.setAbort(session, nil, nil) }
        let status = samples.withUnsafeBufferPointer { native.run(session, $0, params) }
        try abort.check()
        if status == TRANSCRIBE_OK {
            guard !native.wasAborted(session), !native.wasTruncated(session) else { throw Failure.invalidNativeResult }
            return try copiedText(native.fullText(session))
        }
        if [TRANSCRIBE_ERR_ABORTED, TRANSCRIBE_ERR_OUTPUT_TRUNCATED, TRANSCRIBE_ERR_OUTPUT_REPETITION].contains(status) {
            throw Self.failure(status, partial: try copiedText(native.fullText(session)), raw: try copiedText(native.rawText(session)))
        }
        // INVALID_ARG and other non-result-bearing failures may expose an old
        // success in session storage; it must not become this run's recovery.
        throw Self.failure(status)
    }

    private func copiedText(_ pointer: UnsafePointer<CChar>?) throws -> String {
        guard let pointer, let result = String(validatingCString: pointer) else { throw Failure.invalidNativeResult }
        return result
    }

    private func serialized<T: Sendable>(_ work: @escaping @Sendable (Abort) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let abort = Abort(deadline: LocalGeneration.deadline)
        let id = UUID()
        try lock.withLock {
            guard closing == 0 else { throw CancellationError() }
            operations[id] = abort
        }
        defer { _ = lock.withLock { operations.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            let result: T = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try abort.check()
                        let result = try work(abort)
                        try abort.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { abort.cancel() }
    }

    private func flush(through sample: Int?) async {
        let currentEpoch = lock.withLock { epoch }
        do {
            try await serialized { abort in
                _ = try self.flushCaptured(abort: abort, epoch: currentEpoch, through: sample, deliver: true)
            }
        } catch {
            if !(error is CancellationError) { failCapture(error, epoch: currentEpoch) }
        }
    }

    // Called only on queue. Copy admission is not a completed watermark: the
    // completion advances after decode and any final callback have returned.
    private func flushCaptured(abort: Abort, epoch expected: Int, through sample: Int?, deliver: Bool) throws -> String? {
        let batch: ([Float], Int, Int)? = try lock.withLock {
            guard running, !failed, epoch == expected else { return nil }
            let target = sample ?? acceptedSamples
            guard target <= acceptedSamples else { throw Failure.invalidAudio }
            let count = min(pending.count, max(0, target - completedSamples))
            guard count > 0 else { return nil }
            let start = acceptedSamples - pending.count
            let samples = Array(pending.prefix(count))
            return (samples, start, start + count)
        }
        guard let (samples, start, end) = batch else { return nil }
        let text = try decode(samples, abort: abort)
        try abort.check()
        let callback: (@Sendable (TranscriptChunk) -> Void)? = try lock.withLock {
            guard running, !failed, epoch == expected else { throw CancellationError() }
            try abort.check()
            return deliver ? emit : nil
        }
        capturedText = DictationTranscriptMerger.merge([capturedText, text])
        if !text.isEmpty, let callback {
            callback(TranscriptChunk(text: text, isFinal: true, start: Double(start) / 16_000, end: Double(end) / 16_000))
        }
        // Until commit, pending includes this in-flight batch. A superseded
        // gap can cancel and retry without losing PCM or jumping the watermark.
        // Once a callback has returned, commit even if that gap was cancelled
        // during delivery: replaying an already-delivered batch duplicates text.
        lock.withLock {
            if epoch == expected && !failed {
                pending.removeFirst(samples.count)
                completedSamples = end
            }
        }
        return text
    }

    private func failCapture(_ error: Error, epoch expected: Int) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard epoch == expected, running, !failed else { return nil }
            failed = true
            accepting = false
            pending.removeAll(keepingCapacity: false)
            emit = nil
            for abort in operations.values { abort.cancel() }
            return failureHandler
        }
        // Only our fixed description/status reaches the pipeline diagnostics.
        handler?((error as? Failure)?.description ?? "Granite native processing failed.")
    }

    private func resetCapture() {
        capturedText = ""
        lock.withLock {
            pending.removeAll(keepingCapacity: false)
            acceptedSamples = 0
            completedSamples = 0
            running = false
            accepting = false
            emit = nil
        }
    }

    private func close(releasing: Bool) async {
        let abort = Abort(deadline: nil)
        let id = UUID()
        let currentEpoch = lock.withLock { () -> Int in
            closing += 1
            accepting = false
            if releasing {
                epoch += 1
                running = false
                emit = nil
                for operation in operations.values { operation.cancel() }
            } else {
                // Ordinary caption Stop preserves admitted work and the final
                // callback. Explicit release can still cancel this final flush.
                operations[id] = abort
            }
            return epoch
        }
        await withCheckedContinuation { continuation in
            queue.async {
                if !releasing {
                    do {
                        _ = try self.flushCaptured(abort: abort, epoch: currentEpoch, through: nil, deliver: true)
                    } catch {
                        if !(error is CancellationError) { self.failCapture(error, epoch: currentEpoch) }
                    }
                }
                self.resetCapture()
                if releasing {
                    if let session = self.session { self.native.freeSession(session); self.session = nil }
                    if let model = self.model { self.native.freeModel(model); self.model = nil }
                    self.lock.withLock { self.format = nil }
                }
                self.lock.withLock {
                    // Requests admitted before Stop but enqueued behind it
                    // must not resurrect the finished capture after reset.
                    for operation in self.operations.values { operation.cancel() }
                    self.operations.removeValue(forKey: id)
                    self.closing -= 1
                }
                continuation.resume()
            }
        }
    }

    private func fence() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
