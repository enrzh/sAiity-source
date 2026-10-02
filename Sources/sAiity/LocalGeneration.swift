import Foundation
import SaiityLLM

/// One policy for both cleanup and translation, separate from context capacity.
enum LocalGeneration {
    @TaskLocal static var deadline: ContinuousClock.Instant?

    static func outputLimit(inputTokens: Int, promptTokens: Int) -> Int? {
        let requested = min(1_024, max(96, inputTokens * 3 + 32))
        return promptTokens + requested + 16 <= 2_048 ? requested : nil
    }

    static func run(_ model: LLM, user: String, payload: String,
                    thinking: ThinkingMode = .none) async throws -> String? {
        guard !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let framed = model.template?.preprocess(user, [], thinking) ?? user
        let promptTokens = await model.encode(framed).count
        let inputTokens = await model.encode(payload).count
        guard let limit = outputLimit(inputTokens: inputTokens, promptTokens: promptTokens) else {
            NSLog("sAiity generation: context budget insufficient, input=%d prompt=%d", inputTokens, promptTokens)
            return nil
        }
        let remaining = deadline.map { seconds(ContinuousClock.now.duration(to: $0)) } ?? 15
        guard remaining > 0, !Task.isCancelled else { return nil }
        await model.core.setGenerationBudget(maximumGeneratedTokens: limit, maximumDuration: min(15, remaining))
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
                Diagnostics.recordTiming(operation: "model.generation", seconds: elapsed, cold: false)
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
