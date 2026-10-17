import Foundation
import SaiityLLM

/// One policy for cleanup, translation, and a saved-transcript summary.
/// Cleanup and translation size the output from the input. A summary passes
/// `outputTokens` because its output is short and must not grow with the meeting.
enum LocalGeneration {
    @TaskLocal static var deadline: ContinuousClock.Instant?
    @TaskLocal static var dictationRunID: String?
    @TaskLocal static var timingObserver: (@MainActor @Sendable (DiagnosticsRuntimeTiming) -> Void)?

    static func checkDeadline() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CancellationError() }
    }

    static func loadModel<T>(assetID: String? = nil, _ load: () async throws -> T,
                             onTiming: (@MainActor (DiagnosticsRuntimeTiming) -> Void)? = nil) async throws -> T {
        try checkDeadline()
        let started = ContinuousClock.now
        let runID = dictationRunID
        let record: @MainActor () -> Void = {
            let timing = DiagnosticsRuntimeTiming(date: Date(), operation: "model.load",
                seconds: seconds(started.duration(to: .now)), cold: true, runID: runID, modelLoadCount: 1)
            if let onTiming { onTiming(timing) }
            else {
                Diagnostics.recordTiming(operation: timing.operation, seconds: timing.seconds, cold: timing.cold,
                                         runID: timing.runID, modelLoadCount: timing.modelLoadCount)
            }
        }
        let model: T
        do { model = try await load() }
        catch {
            await record()
            if let assetID, LoadHealth.shouldRecordLoadFailure(error) {
                await MainActor.run {
                    LoadHealth.recordFailureIfInstalled(assetID, reason: DiagnosticsRedactor.redact(error.localizedDescription))
                }
            }
            throw error
        }
        await record()
        if let assetID { await MainActor.run { LoadHealth.clear(assetID) } }
        try checkDeadline()
        return model
    }

    @MainActor
    static func recordModelTiming(_ operation: String, since started: ContinuousClock.Instant,
                                  cold: Bool, loads: Int? = nil, calls: Int? = nil) {
        Diagnostics.recordTiming(operation: operation, seconds: seconds(started.duration(to: .now)), cold: cold,
                                 modelLoadCount: loads, modelCallCount: calls)
    }

    static func outputLimit(inputTokens: Int, promptTokens: Int) -> Int? {
        let requested = min(1_024, max(96, inputTokens * 3 + 32))
        return promptTokens + requested + 16 <= 2_048 ? requested : nil
    }

    /// A fixed output that still has to fit the 2,048-token context with the prompt.
    static func fixedOutputLimit(promptTokens: Int, outputTokens: Int, contextTokens: Int = 2_048) -> Int? {
        guard outputTokens > 0, promptTokens >= 0,
              promptTokens + outputTokens + 16 <= contextTokens else { return nil }
        return outputTokens
    }

    static func run(_ model: LLM, user: String, payload: String,
                    thinking: ThinkingMode = .none,
                    outputTokens: Int? = nil,
                    maximumDuration: Double = 15) async throws -> String? {
        try checkDeadline()
        let started = ContinuousClock.now
        let framed = model.template?.preprocess(user, [], thinking) ?? user
        let promptTokens = await model.encode(framed).count
        let limit: Int?
        if let outputTokens {
            limit = fixedOutputLimit(promptTokens: promptTokens, outputTokens: outputTokens)
            if limit == nil {
                NSLog("sAiity generation: fixed budget insufficient, prompt=%d output=%d", promptTokens, outputTokens)
            }
        } else {
            let inputTokens = await model.encode(payload).count
            limit = outputLimit(inputTokens: inputTokens, promptTokens: promptTokens)
            if limit == nil {
                NSLog("sAiity generation: context budget insufficient, input=%d prompt=%d", inputTokens, promptTokens)
            }
        }
        guard let limit else { return nil }
        let remaining = deadline.map { seconds(ContinuousClock.now.duration(to: $0)) } ?? maximumDuration
        guard remaining > 0, !Task.isCancelled else { return nil }
        await model.core.setGenerationBudget(maximumGeneratedTokens: limit,
                                             maximumDuration: min(maximumDuration, remaining))
        // Stream termination cancels the exact native generation task. A
        // detached stop request could arrive after a subsequent request starts.
        do {
            await model.respond(to: user, thinking: thinking)
            // Cancellation can end a consumer stream before the native loop.
            await model.core.waitForGeneration()
            let limited = await model.core.generationWasLimited
            let tokens = await model.core.generatedTokenCount
            let failed = await model.core.generationFailed
            let prefill = await model.core.promptEvaluationSeconds
            let elapsed = seconds(started.duration(to: .now))
            NSLog("sAiity generation: prompt=%d output=%d limited=%@ elapsed=%.3fs", promptTokens, tokens, limited.description, elapsed)
            await MainActor.run {
                Diagnostics.recordTiming(operation: "model.generation", seconds: elapsed, cold: false, modelCallCount: 1)
                Diagnostics.recordTiming(operation: "model.prompt", seconds: prefill, cold: false)
                Diagnostics.recordTiming(operation: "model.decode", seconds: max(0, elapsed - prefill), cold: false)
                if limited { Diagnostics.recordFailure(operation: "model.generation", reason: "generation budget exhausted") }
                if failed { Diagnostics.recordFailure(operation: "model.generation", reason: "native decode failed") }
            }
            if failed { throw TranslationEngineError.runtimeUnavailable(String(localized: "The local model could not finish decoding.")) }
            guard !Task.isCancelled, !limited else { return nil }
            return model.output
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
