import AVFoundation
import FluidAudio
import Foundation

struct CaptionSpeakerAnnotation: Equatable, Sendable {
    let speaker: String?
    let overlapping: Bool

    static func label(speaker: String?, overlapping: Bool, localized: Bool = true) -> String? {
        if overlapping { return localized ? String(localized: "Overlapping voices") : "Overlapping voices" }
        guard let speaker, speaker.hasPrefix("voice-") else { return nil }
        let parts = speaker.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count, Set(numbers).count == numbers.count,
              numbers.allSatisfy({ (1...10).contains($0) }) else { return nil }
        if numbers.count > 1 {
            let labels = numbers.sorted().map(String.init).joined(separator: ", ")
            return localized ? String(localized: "Speakers \(labels)") : "Speakers \(labels)"
        }
        let number = numbers[0]
        return localized ? String(localized: "Speaker \(number)") : "Speaker \(number)"
    }
}

/// Only confirmed audio evidence is labelled. A pause, a language switch or
/// different wording is never treated as a different person.
struct CaptionSpeakerTimeline: Sendable {
    struct Frame: Sendable {
        let start: Double
        let end: Double
        let speakers: [Int]
    }
    private(set) var frames: [Frame] = []
    private(set) var confirmedThrough = 0.0
    static let retainedSeconds = 120.0

    mutating func append(_ newFrames: [Frame]) {
        for frame in newFrames {
            guard frame.start.isFinite, frame.end.isFinite, frame.start >= 0,
                  frame.end > frame.start, frame.start >= confirmedThrough - 0.000001 else { continue }
            frames.append(frame)
            confirmedThrough = frame.end
        }
        frames.removeAll { $0.end < confirmedThrough - Self.retainedSeconds }
    }

    func annotation(start: Double, end: Double) -> CaptionSpeakerAnnotation? {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              end <= confirmedThrough + 0.05 else { return nil }
        var durations: [Int: Double] = [:]
        var covered = 0.0
        var speech = 0.0
        var overlap = 0.0
        var through = start
        for frame in frames where frame.end > start && frame.start < end {
            guard max(frame.start, start) <= through + 0.000001 else { return nil }
            through = max(through, min(frame.end, end))
            let duration = max(0, min(frame.end, end) - max(frame.start, start))
            covered += duration
            guard !frame.speakers.isEmpty else { continue }
            speech += duration
            if frame.speakers.count > 1 { overlap += duration }
            for speaker in frame.speakers { durations[speaker, default: 0] += duration }
        }
        guard through >= end - 0.000001, covered >= (end - start) * 0.8, speech >= 0.2 else { return nil }
        if overlap >= max(0.2, speech * 0.15) { return .init(speaker: nil, overlapping: true) }
        // ASR without word timestamps cannot place a voice boundary inside a
        // sentence. Name both voices on that row instead of guessing the words.
        let voices = durations.filter { $0.value >= 0.2 }.keys.sorted()
        guard !voices.isEmpty else { return nil }
        return .init(speaker: "voice-" + voices.map { String($0 + 1) }.joined(separator: ","), overlapping: false)
    }
}

/// An optional caption-only CPU worker. Never delays ASR or calls into its
/// engine. Bounded backlog; overload disables labels instead of losing captions
/// or feeding a discontinuous audio clock to the recurrent diarizer.
final class CaptionSpeakerTracker: @unchecked Sendable {
    struct Engine: @unchecked Sendable {
        let process: ([Float]) throws -> [CaptionSpeakerTimeline.Frame]
        let finish: () throws -> [CaptionSpeakerTimeline.Frame]
        let stop: () -> Void
    }
    static let preferenceKey = "captionIdentifySpeakers"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }
    static let assetID = "captions.speakers.lseend"
    static let directory = ModelRegistry.root.appendingPathComponent("caption-speakers", isDirectory: true)
    static var modelURL: URL {
        let repo = LSEENDVariant.dihard3.repo
        return directory.appendingPathComponent(repo.folderName)
            .appendingPathComponent(repo.subPath ?? "")
            .appendingPathComponent(LSEENDVariant.dihard3.fileName(forStep: .step100ms))
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("saiity-complete").path)
            && FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("model.mil").path)
    }

    static var asset: ModelAsset {
        .init(id: assetID, family: .recognition,
              title: String(localized: "Speaker identification"),
              detail: String(localized: "Local voice labels for captions. Up to 10 speakers; overlapping voices are marked, not separated."),
              recommended: false, licence: nil, advertisedBytes: nil,
              storage: .directory(directory, markers: ["saiity-complete", modelURL.path.replacingOccurrences(of: directory.path + "/", with: "") + "/model.mil"]), removal: .remove(directory),
              use: .captionSpeakers, install: { progress in
                  progress(.init(fraction: nil, note: String(localized: "Downloading speaker identification…")))
                  let model = try await LSEENDModel.loadFromHuggingFace(cacheDirectory: directory)
                  try Task.checkCancellation()
                  _ = model.metadata
                  try Data("complete".utf8).write(to: directory.appendingPathComponent("saiity-complete"), options: .atomic)
              })
    }

    static func installedEngine() throws -> Engine {
        guard isInstalled else { throw TranslationEngineError.notAvailable(String(localized: "Download Speaker identification from Models first.")) }
        let model = try LSEENDModel(modelURL: modelURL)
        let config = DiarizerTimelineConfig(numSpeakers: model.metadata.maxSpeakers,
            frameDurationSeconds: model.metadata.frameDurationSeconds,
            maxStoredFrames: 1, storeSegments: false)
        let diarizer = try LSEENDDiarizer(model: model, timelineConfig: config)
        func frames(_ update: DiarizerTimelineUpdate?) -> [CaptionSpeakerTimeline.Frame] {
            guard let update else { return [] }
            let result = update.chunkResult
            let count = model.metadata.maxSpeakers
            let duration = Double(model.metadata.frameDurationSeconds)
            return (0..<result.finalizedFrameCount).map { frame in
                .init(start: Double(result.startFrame + frame) * duration,
                      end: Double(result.startFrame + frame + 1) * duration,
                      speakers: (0..<count).filter { result.probability(speaker: $0, frame: frame, numSpeakers: count) >= 0.65 })
            }
        }
        return Engine(process: { frames(try diarizer.process(samples: $0, sourceSampleRate: 16_000)) },
                      finish: { frames(try diarizer.finalizeSession()) }, stop: { diarizer.cleanup() })
    }

    static let maximumPendingSamples = 16_000 * 5
    private let queue = DispatchQueue(label: "saiity.caption-speakers", qos: .userInitiated)
    private let lock = NSLock()
    private var engine: Engine?
    private var pending: [Float] = []
    private var pumping = false
    private var accepting = true
    private var failed = false
    private var timeline = CaptionSpeakerTimeline()
    private let onUpdate: @Sendable (CaptionSpeakerTimeline) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(engine: Engine, onUpdate: @escaping @Sendable (CaptionSpeakerTimeline) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              let samples = buffer.floatChannelData?[0] else { return }
        feed(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
    }

    func feed(_ samples: [Float]) {
        let schedule = lock.withLock { () -> Bool in
            guard accepting else { return false }
            if pending.count + samples.count > Self.maximumPendingSamples {
                accepting = false
                failed = true
                pending.removeAll()
            } else { pending.append(contentsOf: samples) }
            guard !pumping, pending.count >= 3_200 || failed else { return false }
            pumping = true
            return true
        }
        if schedule { queue.async { self.pump() } }
    }

    private func pump() {
        while true {
            let (samples, overflow) = lock.withLock { () -> ([Float], Bool) in
                guard pending.count >= 3_200 || failed else { pumping = false; return ([], false) }
                let next = Array(pending.prefix(3_200))
                pending.removeFirst(next.count)
                return (next, failed)
            }
            if overflow { fail("Speaker identification could not keep up; captions continue."); return }
            guard !samples.isEmpty else { return }
            do { if let engine { publish(try engine.process(samples)) } }
            catch { fail(DiagnosticsRedactor.redact(error.localizedDescription)); return }
        }
    }

    private func publish(_ frames: [CaptionSpeakerTimeline.Frame]) {
        guard !frames.isEmpty else { return }
        timeline.append(frames)
        onUpdate(timeline)
    }

    private func fail(_ reason: String) {
        lock.withLock { accepting = false; failed = true; pending.removeAll(); pumping = false }
        engine?.stop()
        engine = nil
        onFailure(reason)
    }

    @discardableResult func stop() async -> CaptionSpeakerTimeline {
        lock.withLock { accepting = false }
        return await withCheckedContinuation { continuation in
            queue.async {
                let remainder = self.lock.withLock { () -> [Float] in
                    defer { self.pending.removeAll() }
                    return self.pending
                }
                do {
                    if let engine = self.engine {
                        if !remainder.isEmpty { self.publish(try engine.process(remainder)) }
                        self.publish(try engine.finish())
                        engine.stop()
                    }
                } catch { self.fail(DiagnosticsRedactor.redact(error.localizedDescription)) }
                self.engine = nil
                continuation.resume(returning: self.timeline)
            }
        }
    }
}

final class CaptionSpeakerSink: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: CaptionSpeakerTracker?
    func point(at tracker: CaptionSpeakerTracker?) { lock.withLock { self.tracker = tracker } }
    func feed(_ buffer: AVAudioPCMBuffer) { lock.withLock { tracker }?.feed(buffer) }
}
