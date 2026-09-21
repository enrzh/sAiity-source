import AVFoundation
import FluidAudio
import Foundation

/// The one diarization artifact the app owns. Keeping it in the same model root
/// as ASR/translation makes the existing Models page and delete safeguards apply
/// without teaching FluidAudio about app-specific storage.
enum SpeakerDiarizationModel {
    static let assetID = AssetID.speakerDiarization
    private static let remotePath = "100ms/ls_eend_dih3_100ms.mlmodelc"

    static var modelDirectory: URL {
        ModelRegistry.root
            .appendingPathComponent(Repo.lseendDihard3.folderName, isDirectory: true)
            .appendingPathComponent("100ms", isDirectory: true)
    }

    static var modelURL: URL {
        modelDirectory.appendingPathComponent("ls_eend_dih3_100ms.mlmodelc", isDirectory: true)
    }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    static let asset = ModelAsset(
        id: assetID,
        family: .recognition,
        title: String(localized: "Identify speakers"),
        detail: String(localized: "Optional local speaker identification model for live captions."),
        recommended: false,
        licence: "NVIDIA Open Model License",
        advertisedBytes: nil,
        storage: .directory(modelDirectory,
                            markers: ["ls_eend_dih3_100ms.mlmodelc"]),
        removal: .remove(modelDirectory),
        use: .whenSpeakerDiarization,
        install: { progress in
            try await download(progress: progress)
        })

    static func download(progress: @escaping ProgressSink) async throws {
        guard !isDownloaded else { return }
        try await ModelHub.download(
            Repo.lseendDihard3,
            subdirectory: remotePath,
            to: ModelRegistry.root,
            progressHandler: { update in
                progress(DownloadProgress(
                    fraction: update.fractionCompleted,
                    note: String(localized: "Downloading speaker identification model…")))
            })
    }

    static func makeDiarizer() async throws -> LSEENDDiarizer {
        try await DownloadCoordinator.shared.run(assetID) {
            if !isDownloaded {
                try await download { _ in }
            }
        }
        let model = try await LSEENDModel.loadFromHuggingFace(
            variant: .dihard3,
            stepSize: .step100ms,
            cacheDirectory: ModelRegistry.root)
        return try LSEENDDiarizer(model: model)
    }
}

/// Owns one streaming diarizer for one caption session.
///
/// FluidAudio's diarizers are not thread-safe. Audio capture therefore only
/// copies samples into this queue; one task is the sole caller of `process()`.
/// The model is prepared once and reset between sessions, so stopping captions
/// does not leave another native inference operation running.
final class SpeakerDiarizationSession: @unchecked Sendable {
    typealias EventHandler = @Sendable ([SpeakerDiarizationEvent]) -> Void

    private let queueLock = NSLock()
    private var pending: [Float] = []
    private var processing: [Float] = []
    private var running = false
    private var processingTask: Task<Void, Never>?
    private var handler: EventHandler?
    private var sourceSampleRate: Double = 16_000
    private var processedAudioSamples = 0
    private var processingWallSeconds = 0.0
    private var processedBatchCount = 0
    private var peakPendingSamples = 0

    // LS-EEND keeps up comfortably when healthy. If it falls behind by more
    // than this, labels are less useful than uninterrupted captions, so the
    // optional feature disables itself for this session instead of growing
    // memory without bound.
    private static let maxPendingSeconds = 5.0
    private var diarizer: LSEENDDiarizer?

    var isPrepared: Bool {
        queueLock.withLock { diarizer != nil }
    }

    func prepare() async throws {
        if isPrepared { return }
        let loaded = try await SpeakerDiarizationModel.makeDiarizer()
        queueLock.withLock { diarizer = loaded }
    }

    func start(sourceSampleRate: Double,
               onEvents: @escaping EventHandler) throws {
        guard isPrepared else {
            throw SpeakerDiarizationSessionError.notPrepared
        }
        let task: Task<Void, Never>? = queueLock.withLock {
            guard !running, processingTask == nil else { return nil }
            pending.removeAll(keepingCapacity: true)
            processing.removeAll(keepingCapacity: true)
            processedAudioSamples = 0
            processingWallSeconds = 0
            processedBatchCount = 0
            peakPendingSamples = 0
            running = true
            self.sourceSampleRate = sourceSampleRate
            handler = onEvents
            diarizer?.reset()
            return Task { [weak self] in
                await self?.processLoop()
            }
        }
        guard let task else { throw SpeakerDiarizationSessionError.alreadyRunning }
        queueLock.withLock { processingTask = task }
    }

    /// Called directly from the ScreenCaptureKit callback. It never performs
    /// model work and never waits for the processing task.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        queueLock.withLock {
            guard running else { return }
            pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
            peakPendingSamples = max(peakPendingSamples, pending.count)
            let limit = max(1, Int(sourceSampleRate * Self.maxPendingSeconds))
            if pending.count > limit {
                // The diarizer is optional. Do not drop audio and continue with
                // incorrect timestamps; stop labeling while ASR keeps running.
                pending.removeAll(keepingCapacity: false)
                running = false
                NSLog("sAiity diarization: processing fell behind; disabled for session")
            }
        }
    }

    func stop() async {
        let task = queueLock.withLock { () -> Task<Void, Never>? in
            running = false
            let task = processingTask
            processingTask = nil
            return task
        }
        task?.cancel()
        await task?.value
        logAndResetPerformance()

        // Finalization happens only after the processing loop has left, so the
        // FluidAudio object never sees concurrent process/finalize calls.
        if let update = try? diarizer?.finalizeSession() {
            emit(update)
        }
        diarizer?.reset()
        queueLock.withLock {
            pending.removeAll(keepingCapacity: false)
            processing.removeAll(keepingCapacity: false)
            handler = nil
        }
    }

    func release() async {
        await stop()
        queueLock.withLock {
            diarizer?.cleanup()
            diarizer = nil
        }
    }

    private func processLoop() async {
        while !Task.isCancelled {
            let hasBatch = queueLock.withLock { () -> Bool? in
                guard running else { return nil }
                guard !pending.isEmpty else { return false }
                swap(&pending, &processing)
                return true
            }
            guard let hasBatch else { return }
            if !hasBatch {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            do {
                let batchSamples = processing.count
                let started = ContinuousClock.now
                if let update = try diarizer?.process(samples: processing,
                                                      sourceSampleRate: sourceSampleRate) {
                    emit(update)
                }
                let elapsed = started.duration(to: .now).components
                let wallSeconds = Double(elapsed.seconds)
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                queueLock.withLock {
                    processedAudioSamples += batchSamples
                    processingWallSeconds += wallSeconds
                    processedBatchCount += 1
                }
                queueLock.withLock { processing.removeAll(keepingCapacity: true) }
            } catch {
                NSLog("sAiity diarization unavailable: \(error.localizedDescription)")
                queueLock.withLock {
                    running = false
                    pending.removeAll(keepingCapacity: false)
                    processing.removeAll(keepingCapacity: false)
                }
                return
            }
        }
    }

    private func logAndResetPerformance() {
        let metrics = queueLock.withLock { () -> (Int, Double, Int, Int, Double) in
            defer {
                processedAudioSamples = 0
                processingWallSeconds = 0
                processedBatchCount = 0
                peakPendingSamples = 0
            }
            return (processedAudioSamples, processingWallSeconds,
                    processedBatchCount, peakPendingSamples, sourceSampleRate)
        }
        guard metrics.2 > 0 else { return }
        let audioSeconds = Double(metrics.0) / metrics.4
        let realTimeFactor = metrics.1 / max(audioSeconds, 0.001)
        let peakBacklogSeconds = Double(metrics.3) / metrics.4
        NSLog("sAiity diarization timing: audio=%.3fs compute=%.3fs rtf=%.3f batches=%d peak-backlog=%.3fs",
              audioSeconds, metrics.1, realTimeFactor, metrics.2, peakBacklogSeconds)
    }

    private func emit(_ update: DiarizerTimelineUpdate) {
        let events = SpeakerDiarizationAdapter.events(
            finalized: update.finalizedSegments,
            tentative: update.tentativeSegments)
        guard !events.isEmpty else { return }
        let callback = queueLock.withLock { handler }
        callback?(events)
    }
}

enum SpeakerDiarizationSessionError: LocalizedError {
    case notPrepared
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .notPrepared: return String(localized: "Speaker identification is not ready yet.")
        case .alreadyRunning: return String(localized: "Speaker identification is already running.")
        }
    }
}
