import Foundation
import MLX
import MLXNN
import AudioCommon
import os.log

private let log = OSLog(subsystem: "com.soniqo.madlad", category: "MLX")

/// High-level MADLAD-400 translator.
///
/// ```swift
/// let translator = try await MADLADTranslator.fromPretrained()
/// let es = try translator.translate("Hello world", to: "es")
/// ```
///
/// Greedy decoding is the default and recommended for translation. Sampling
/// is exposed for paraphrase-style use cases.
public final class MADLADTranslator: @unchecked Sendable {

    /// Default HuggingFace repo (MLX-converted MADLAD-400-3B-MT).
    /// The repo is expected to contain `int4/` and `int8/` subdirs, each with
    /// `config.json`, `model.safetensors`, and `tokenizer.json` (matching the
    /// Qwen3.5-Chat-MLX layout).
    public static let defaultModelId = "aufklarer/MADLAD400-3B-MT-MLX"

    /// Quantization variant.
    public enum Quantization: String, Sendable {
        case int4
        case int8
    }

    public let config: MADLADTranslationConfig
    public let tokenizer: MADLADTokenizer
    let model: MADLADTranslationModel

    /// Latest translation metrics.
    public struct Metrics: Sendable {
        public var encodeTimeMs: Double = 0
        public var decodeTimeMs: Double = 0
        public var sourceTokens: Int = 0
        public var generatedTokens: Int = 0

        public var tokensPerSecond: Double {
            guard decodeTimeMs > 0, generatedTokens > 0 else { return 0 }
            return Double(generatedTokens) / (decodeTimeMs / 1000.0)
        }
    }

    private(set) public var lastMetrics = Metrics()

    private init(
        config: MADLADTranslationConfig,
        tokenizer: MADLADTokenizer,
        model: MADLADTranslationModel
    ) {
        self.config = config
        self.tokenizer = tokenizer
        self.model = model
    }

    // MARK: - Factories

    /// Load from a HuggingFace repo with `int4/` and `int8/` subdirectories.
    public static func fromPretrained(
        modelId: String = defaultModelId,
        quantization: Quantization = .int4,
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> MADLADTranslator {
        let cacheDir = try cacheDir ?? HuggingFaceDownloader.getCacheDirectory(for: modelId)
        let variant = quantization.rawValue

        progressHandler?(0.05, "Downloading \(variant) model...")
        try await HuggingFaceDownloader.downloadWeights(
            modelId: modelId,
            to: cacheDir,
            additionalFiles: [
                "\(variant)/model.safetensors",
                "\(variant)/config.json",
                "\(variant)/tokenizer.json",
                "\(variant)/tokenizer_config.json",
                "\(variant)/special_tokens_map.json",
            ],
            offlineMode: offlineMode,
            progressHandler: { progress in
                progressHandler?(progress * 0.5, "Downloading...")
            }
        )

        let variantDir = cacheDir.appendingPathComponent(variant)
        return try await fromLocal(
            directory: variantDir,
            bits: quantization == .int4 ? 4 : 8,
            progressHandler: { p, s in progressHandler?(0.5 + p * 0.5, s) }
        )
    }

    /// Load from a local directory containing `config.json`, `model.safetensors`,
    /// and a tokenizer (`tokenizer.json` etc.).
    public static func fromLocal(
        directory: URL,
        bits: Int = 4,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> MADLADTranslator {
        progressHandler?(0.1, "Loading config...")
        let configURL = directory.appendingPathComponent("config.json")
        let config: MADLADTranslationConfig
        if FileManager.default.fileExists(atPath: configURL.path) {
            config = try MADLADTranslationConfig.load(from: configURL)
        } else {
            config = .madlad3B
        }

        progressHandler?(0.2, "Loading tokenizer...")
        let tokenizer = try await MADLADTokenizer.load(
            from: directory,
            eosTokenId: config.eosTokenId,
            padTokenId: config.padTokenId)

        progressHandler?(0.4, "Creating model...")
        let model = MADLADTranslationModel(config: config, groupSize: 64, bits: bits)

        progressHandler?(0.5, "Loading weights...")
        try MADLADWeightLoader.loadWeights(
            into: model, from: directory,
            progressHandler: { p, s in progressHandler?(0.5 + p * 0.5, s) })

        progressHandler?(1.0, "Ready")
        return MADLADTranslator(config: config, tokenizer: tokenizer, model: model)
    }

    // MARK: - Translate

    /// Translate `text` into `targetLanguage` (ISO 639-1 code, e.g. `"es"`, `"zh"`, `"fr"`).
    ///
    /// MADLAD auto-detects the source language; only the target needs to be specified.
    public func translate(
        _ text: String,
        to targetLanguage: String,
        sampling: TranslationSamplingConfig = .greedy,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> String {
        try Self.checkAdmission(deadline: deadline)
        let inputIds = try tokenizer.encode(text: text, targetLanguage: targetLanguage)
        let generated = try generate(inputIds: inputIds, sampling: sampling, deadline: deadline)
        try Self.checkAdmission(deadline: deadline)
        let translated = tokenizer.decode(generated)
        try Self.checkAdmission(deadline: deadline)
        return translated
    }

    /// Lower-level generate from pre-tokenized input ids.
    ///
    /// Encodes the source once, then runs greedy/sampling decode until
    /// `</s>` or `maxTokens`.
    public func generate(
        inputIds: [Int],
        sampling: TranslationSamplingConfig = .greedy,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> [Int] {
        try Self.checkAdmission(deadline: deadline)
        var metrics = Metrics()
        metrics.sourceTokens = inputIds.count

        // Encode
        let encStart = CFAbsoluteTimeGetCurrent()
        let inputArr = MLXArray(inputIds.map { Int32($0) }).expandedDimensions(axis: 0)
        let encoderOutput = model.encode(inputIds: inputArr)
        eval(encoderOutput)
        try Self.checkAdmission(deadline: deadline)
        metrics.encodeTimeMs = (CFAbsoluteTimeGetCurrent() - encStart) * 1000

        // Decode loop
        var caches = (0..<config.numDecoderLayers).map { _ in DecoderLayerCache() }
        var history: [Int] = []

        let decStart = CFAbsoluteTimeGetCurrent()
        let generated = try Self.decodeTokens(
            sampling: sampling, eosTokenId: config.eosTokenId,
            decoderStartTokenId: config.decoderStartTokenId, deadline: deadline,
            step: { nextToken in
                let stepInput = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
                let logits = model.decodeStep(
                    inputIds: stepInput,
                    encoderOutput: encoderOutput,
                    caches: &caches)
                eval(logits)
                try Self.checkAdmission(deadline: deadline)
                return Self.selectToken(logits[0, 0], vocabSize: self.config.vocabSize,
                                        sampling: sampling, history: history)
            }, didGenerate: { history = $0 })
        metrics.decodeTimeMs = (CFAbsoluteTimeGetCurrent() - decStart) * 1000
        metrics.generatedTokens = generated.count
        self.lastMetrics = metrics

        os_log(.info, log: log,
               "Translated: src=%d tokens (encode %.0f ms), gen=%d tokens (decode %.0f ms, %.1f tok/s)",
               metrics.sourceTokens, metrics.encodeTimeMs,
               metrics.generatedTokens, metrics.decodeTimeMs, metrics.tokensPerSecond)
        return generated
    }

    /// Streaming translate — yields decoded text fragments as they're produced.
    public func translateStream(
        _ text: String,
        to targetLanguage: String,
        sampling: TranslationSamplingConfig = .greedy,
        deadline: ContinuousClock.Instant? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let cancelled = Task.isCancelled
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    if cancelled { throw CancellationError() }
                    try Self.checkAdmission(deadline: deadline)
                    let inputIds = try self.tokenizer.encode(text: text, targetLanguage: targetLanguage)
                    try Self.checkAdmission(deadline: deadline)
                    let inputArr = MLXArray(inputIds.map { Int32($0) }).expandedDimensions(axis: 0)
                    let encoderOutput = self.model.encode(inputIds: inputArr)
                    eval(encoderOutput)
                    try Self.checkAdmission(deadline: deadline)

                    var caches = (0..<self.config.numDecoderLayers).map { _ in DecoderLayerCache() }
                    var history: [Int] = []
                    var yieldedText = ""

                    _ = try Self.decodeTokens(
                        sampling: sampling, eosTokenId: self.config.eosTokenId,
                        decoderStartTokenId: self.config.decoderStartTokenId, deadline: deadline,
                        step: { nextToken in
                            let stepInput = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
                            let logits = self.model.decodeStep(
                                inputIds: stepInput,
                                encoderOutput: encoderOutput,
                                caches: &caches)
                            eval(logits)
                            try Self.checkAdmission(deadline: deadline)
                            return Self.selectToken(logits[0, 0], vocabSize: self.config.vocabSize,
                                                    sampling: sampling, history: history)
                        }, didGenerate: { generated in
                            history = generated
                            // Decode the FULL accumulated sequence each step and
                            // yield the suffix diff. Decoding tokens one at a time
                            // strips the SentencePiece `▁` word-boundary marker,
                            // which collapses spaces (e.g. "Hola mundo" → "Holamundo").
                            let fullText = self.tokenizer.decode(generated)
                            try Self.checkAdmission(deadline: deadline)
                            if fullText.count > yieldedText.count,
                               fullText.hasPrefix(yieldedText) {
                                let start = fullText.index(fullText.startIndex, offsetBy: yieldedText.count)
                                let suffix = String(fullText[start...])
                                if !suffix.isEmpty {
                                    if case .terminated = continuation.yield(suffix) {
                                        throw CancellationError()
                                    }
                                    yieldedText = fullText
                                }
                            }
                        })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    static func selectToken(_ logits: MLXArray, vocabSize: Int,
                            sampling: TranslationSamplingConfig, history: [Int]) -> Int {
        let count = min(vocabSize, logits.size)
        guard count > 0 else { return 0 }
        let scores = logits.asType(.float32)[0..<count]
        if sampling.temperature <= 0 {
            // The pinned CPU loop ignores NaNs and keeps the first maximum.
            let comparable = MLX.where(isNaN(scores), MLXArray(-Float.infinity), scores)
            return comparable.argMax().item(Int.self)
        }
        return sampleWithTemperature(
            logits: scores.asArray(Float.self), temperature: sampling.temperature,
            topK: sampling.topK, topP: sampling.topP, history: history,
            repetitionPenalty: sampling.repetitionPenalty)
    }

    static func checkAdmission(deadline: ContinuousClock.Instant?,
                               now: ContinuousClock.Instant = ContinuousClock.now) throws {
        try Task.checkCancellation()
        if let deadline, now >= deadline {
            throw MADLADTranslationError.inferenceFailed("Translation deadline exceeded")
        }
    }

    static func decodeTokens(sampling: TranslationSamplingConfig, eosTokenId: Int,
                             decoderStartTokenId: Int, deadline: ContinuousClock.Instant?,
                             step: (Int) throws -> Int,
                             didGenerate: ([Int]) throws -> Void) throws -> [Int] {
        try checkAdmission(deadline: deadline)
        var generated: [Int] = []
        var nextToken = decoderStartTokenId
        for _ in 0..<sampling.maxTokens {
            try checkAdmission(deadline: deadline)
            // Cancellation cannot release native state until this synchronous step returns.
            let token = try step(nextToken)
            try checkAdmission(deadline: deadline)
            if token == eosTokenId { break }
            generated.append(token)
            nextToken = token
            try didGenerate(generated)
        }
        try checkAdmission(deadline: deadline)
        return generated
    }
}

// MARK: - Sampling helpers

@inline(__always)
private func greedyArgmax(_ logits: [Float]) -> Int {
    var bestIdx = 0
    var bestVal = -Float.infinity
    for (i, v) in logits.enumerated() where v > bestVal {
        bestVal = v
        bestIdx = i
    }
    return bestIdx
}

private func sampleWithTemperature(
    logits: [Float],
    temperature: Float,
    topK: Int,
    topP: Float,
    history: [Int],
    repetitionPenalty: Float
) -> Int {
    var scaled = logits

    if repetitionPenalty != 1.0 {
        let recent = Set(history.suffix(64))
        for tok in recent {
            guard tok < scaled.count else { continue }
            scaled[tok] = scaled[tok] >= 0
                ? scaled[tok] / repetitionPenalty
                : scaled[tok] * repetitionPenalty
        }
    }

    let invT = 1.0 / max(temperature, 1e-5)
    for i in 0..<scaled.count { scaled[i] *= invT }

    var indexed = scaled.enumerated().map { ($0, $1) }
    indexed.sort { $0.1 > $1.1 }

    if topK > 0 && topK < indexed.count {
        indexed = Array(indexed.prefix(topK))
    }

    let maxLogit = indexed.first?.1 ?? 0
    var probs = indexed.map { exp($0.1 - maxLogit) }
    let sum = probs.reduce(0, +)
    if sum > 0 {
        for i in 0..<probs.count { probs[i] /= sum }
    }

    if topP < 1.0 {
        var cumulative: Float = 0
        var cutoff = probs.count
        for (i, p) in probs.enumerated() {
            cumulative += p
            if cumulative >= topP {
                cutoff = i + 1
                break
            }
        }
        if cutoff < probs.count {
            indexed = Array(indexed.prefix(cutoff))
            probs = Array(probs.prefix(cutoff))
            let s = probs.reduce(0, +)
            if s > 0 {
                for i in 0..<probs.count { probs[i] /= s }
            }
        }
    }

    let r = Float.random(in: 0..<1)
    var acc: Float = 0
    for (i, p) in probs.enumerated() {
        acc += p
        if r < acc { return indexed[i].0 }
    }
    return indexed.last?.0 ?? 0
}
