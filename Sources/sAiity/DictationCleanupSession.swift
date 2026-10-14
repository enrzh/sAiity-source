import Foundation

/// A dictation-only warm model, sharing the native inference gate with translation.
/// Whole requests (including teardown) own the gate, never individual tokens.
@MainActor
final class DictationCleanupSession {
    struct Model {
        let cleanup: (String, String?, DictationLanguageMetadata) async -> String?
        /// Optional one-call path for mixed language regions. The caller still
        /// validates every returned region independently before accepting it.
        let cleanupRegions: (([DictationRegionTranscript]) async -> [String]?)?
        let stop: () async -> Void

        init(cleanup: @escaping (String, String?, DictationLanguageMetadata) async -> String?,
             cleanupRegions: (([DictationRegionTranscript]) async -> [String]?)? = nil,
             stop: @escaping () async -> Void) {
            self.cleanup = cleanup
            self.cleanupRegions = cleanupRegions
            self.stop = stop
        }
    }

    private let gate: TranslationInferenceGate
    private let idleDelay: Duration
    private let idle = IdleEviction()
    private let onTiming: (DiagnosticsRuntimeTiming) -> Void
    private var model: Model?
    private var modelKey: String?

    init(gate: TranslationInferenceGate, idleDelay: Duration = .seconds(300),
         onTiming: @escaping (DiagnosticsRuntimeTiming) -> Void = { _ in }) {
        self.gate = gate
        self.idleDelay = idleDelay
        self.onTiming = onTiming
    }

    func cleanup(_ input: DictationTranscriptionResult,
                 modelKey key: String?,
                 load: @escaping @MainActor () async throws -> Model) async -> DictationTranscriptionResult? {
        idle.cancel()
        defer {
            idle.schedule(after: idleDelay, shouldEvict: { [weak self] in
                self?.model != nil
            }, evict: { [weak self] in await self?.invalidate() })
        }
        do {
            return try await gate.run { [self] in
                try await LocalGeneration.$deadline.withValue(.now.advanced(by: .seconds(15))) {
                    try await process(input, key: key, load: load)
                }
            }
        } catch {
            Diagnostics.recordFailure(operation: "dictation.cleanup", reason: "model unavailable or cancelled")
            NSLog("sAiity cleanup unavailable: %@", DiagnosticsRedactor.redact(error.localizedDescription))
            return nil
        }
    }

    func invalidate() async {
        idle.cancel()
        _ = try? await gate.run { [self] in await releaseModel() }
    }

    /// Caller must already own the shared gate. Used during translator loading
    /// to avoid retaining both native text models at once.
    func releaseModel() async {
        let outgoing = model
        model = nil
        modelKey = nil
        await outgoing?.stop()
    }

    private func process(_ input: DictationTranscriptionResult,
                         key: String?,
                         load: @MainActor () async throws -> Model) async throws -> DictationTranscriptionResult {
        let start = ContinuousClock.now
        var modelCalls = 0
        var modelLoads = 0
        var loadSeconds = 0.0
        var skipped = 0
        var accepted = 0
        var rejected = 0
        var modelUnavailable = false
        defer {
            let elapsed = start.duration(to: .now).components
            NSLog("sAiity cleanup: regions=%d modelCalls=%d skipped=%d accepted=%d rejected=%d load=%.3fs total=%.3fs",
                  input.regions.count, modelCalls, skipped, accepted, rejected, loadSeconds,
                  Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            onTiming(.init(date: Date(), operation: "dictation.cleanup.requests",
                           seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                           cold: modelLoads > 0 ? true : modelCalls > 0 ? false : nil,
                           runID: LocalGeneration.dictationRunID,
                           modelLoadCount: modelLoads, modelCallCount: modelCalls))
        }
        if modelKey != key { await releaseModel() }

        // A single-language recording may still be split into several audio
        // regions for recognition. Cleaning the joined transcript once is both
        // faster and more accurate for corrections that cross a region seam.
        // Mixed-language input stays region-local so the model cannot flatten
        // intentional code-switching.
        if !input.languageMetadata.containsMultipleLanguages {
            let source = input.languageMetadata.dominantLanguage
                ?? input.regions.first?.language
            let metadata = input.languageMetadata
            // One deterministic pass, not two: the baseline is also what
            // decides whether the model is needed at all, so asking for both
            // together is the same work as asking for the answer twice.
            let outcome = DictationCleanupValidator.deterministicOutcome(
                input.text, sourceLanguage: source)
            let baseline = outcome.baseline
            var candidate = baseline
            var modelReturnedOutput = false
            if outcome.needsModel, key == nil { modelUnavailable = true }
            if key != nil, outcome.needsModel {
                if model == nil {
                    let loading = ContinuousClock.now
                    modelLoads += 1
                    model = try await load()
                    modelKey = key
                    let elapsed = loading.duration(to: .now).components
                    loadSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                }
                try Task.checkCancellation()
                modelCalls = 1
                if let value = await model?.cleanup(input.text, source, metadata) {
                    candidate = value
                    modelReturnedOutput = true
                }
                else { modelUnavailable = true }
                try Task.checkCancellation()
            }
            let cleaned = DictationCleanupValidator.validate(candidate,
                preserving: input.text, sourceLanguage: source, languageMetadata: metadata)
                ?? DictationCleanupValidator.validate(baseline,
                    preserving: input.text, sourceLanguage: source, languageMetadata: metadata)
                ?? input.text
            if modelCalls == 0 { skipped += 1 }
            else if modelReturnedOutput, cleaned == candidate { accepted += 1 }
            else { rejected += 1; modelUnavailable = true }
            let language = source ?? input.regions.first?.language
            var result = DictationTranscriptionResult(regions: [
                .init(text: cleaned, language: language)
            ])
            result.modelCleanupUnavailable = modelUnavailable
            result.modelCalls = modelCalls
            result.modelAccepted = accepted
            result.modelFallbacks = rejected
            result.rulesSkipped = skipped
            return result
        }

        // Computed once per region and kept, because the loop below needs the
        // same baseline as its fallback — asking the validator twice meant
        // running the deterministic pass twice over every region.
        var baselines: [Int: String] = [:]
        let modelIndexes: [Int] = input.regions.indices.filter { index in
            let region = input.regions[index]
            let outcome = DictationCleanupValidator.deterministicOutcome(
                region.text,
                sourceLanguage: region.language == "auto" ? nil : region.language)
            baselines[index] = outcome.baseline
            if outcome.needsModel, key == nil { modelUnavailable = true }
            return key != nil && outcome.needsModel
        }
        if !modelIndexes.isEmpty, model == nil {
            let loading = ContinuousClock.now
            modelLoads += 1
            model = try await load()
            modelKey = key
            let elapsed = loading.duration(to: .now).components
            loadSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }

        var batched: [Int: String] = [:]
        if modelIndexes.count > 1, let cleanupRegions = model?.cleanupRegions {
            try Task.checkCancellation()
            modelCalls = 1
            let requested = modelIndexes.map { input.regions[$0] }
            if let values = await cleanupRegions(requested), values.count == requested.count {
                for (offset, value) in values.enumerated() {
                    let region = requested[offset]
                    let source = region.language == "auto" ? nil : region.language
                    let metadata = DictationLanguageMetadata(regions: [region])
                    // A region whose output fails validation is simply not
                    // recorded, so it falls through to the sequential path
                    // below. The previous code set a `valid` flag, broke out,
                    // and cleared the whole batch — so one malformed region of
                    // five sent *all five* back through the model individually:
                    // one wasted batched call plus five sequential ones. A
                    // partial batch is still worth far more than none.
                    guard let cleaned = DictationCleanupValidator.validate(
                        value,
                        preserving: region.text,
                        sourceLanguage: source,
                        languageMetadata: metadata) else { continue }
                    batched[modelIndexes[offset]] = cleaned
                }
            }
            try Task.checkCancellation()
        }

        let modelIndexSet = Set(modelIndexes)
        var regions: [DictationRegionTranscript] = []
        regions.reserveCapacity(input.regions.count)
        for (index, region) in input.regions.enumerated() {
            try Task.checkCancellation()
            let source = region.language == "auto" ? nil : region.language
            let metadata = DictationLanguageMetadata(regions: [region])
            let baseline = baselines[index]
                ?? DictationCleanupValidator.deterministicCleanup(
                    region.text, sourceLanguage: source)
            var candidate = baseline
            var modelReturnedOutput = false
            if let value = batched[index] {
                candidate = value
                modelReturnedOutput = true
            } else if modelIndexSet.contains(index) {
                modelCalls += 1
                if let value = await model?.cleanup(region.text, source, metadata) {
                    candidate = value
                    modelReturnedOutput = true
                }
                else { modelUnavailable = true }
                try Task.checkCancellation()
            }
            let cleaned = DictationCleanupValidator.validate(candidate,
                preserving: region.text, sourceLanguage: source, languageMetadata: metadata)
                ?? DictationCleanupValidator.validate(baseline,
                    preserving: region.text, sourceLanguage: source, languageMetadata: metadata)
                ?? region.text
            if !modelIndexSet.contains(index) { skipped += 1 }
            else if modelReturnedOutput, cleaned == candidate { accepted += 1 }
            else { rejected += 1; modelUnavailable = true }
            regions.append(.init(text: cleaned, language: region.language))
        }
        var result = DictationTranscriptionResult(regions: regions)
        if DictationCleanupValidator.validate(result.text, preserving: input.text,
            sourceLanguage: input.languageMetadata.dominantLanguage,
            languageMetadata: input.languageMetadata) == nil {
            result = input
            modelUnavailable = true
            accepted = 0
            rejected = modelIndexes.count
        }
        result.modelCleanupUnavailable = modelUnavailable
        result.modelCalls = modelCalls
        result.modelAccepted = accepted
        result.modelFallbacks = rejected
        result.rulesSkipped = skipped
        return result
    }

}
