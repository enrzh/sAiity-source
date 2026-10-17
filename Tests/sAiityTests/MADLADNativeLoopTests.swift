// External draft: MAIN moves this into its test target for serial RED.
// Tiny synthetic scores only; MLX still needs MAIN's supported metallib harness.
import Foundation
import MLX
import Testing

@testable import SaiityMADLAD

@Suite struct MADLADNativeLoopTests {
    @Test("greedy selection uses the Float32 vocabulary prefix", arguments: [DType.float32, .float16, .bfloat16])
    func greedyVocabularyPrefix(dtype: DType) {
        let logits = MLXArray([Float(-4), 2, 7, 7, 1000]).asType(dtype)
        let token = MADLADTranslator.selectToken(logits, vocabSize: 4,
                                                sampling: .greedy, history: [])
        #expect(token == 2, "padding outside the configured vocabulary must not win")
    }

    @Test("greedy ties retain the first vocabulary index")
    func greedyFirstTie() {
        let cases: [[Float]] = [[8, 8, 1], [-5, -2, -2], [-Float.infinity, -Float.infinity]]
        for values in cases {
            let token = MADLADTranslator.selectToken(MLXArray(values), vocabSize: values.count,
                                                    sampling: .greedy, history: [])
            #expect(token == cpuArgmax(values))
        }
    }

    @Test("greedy scores match the pinned CPU algorithm across finite synthetic inputs")
    func greedyMatchesReference() {
        for seed in 0..<32 {
            let values = (0..<17).map { Float(($0 * 11 + seed * 7) % 23 - 11) }
            let token = MADLADTranslator.selectToken(MLXArray(values + [1000]), vocabSize: values.count,
                                                    sampling: .greedy, history: [])
            #expect(token == cpuArgmax(values))
        }
    }

    @Test("the stochastic path keeps vocabulary bounds and repetition penalty")
    func samplingKeepsExistingBehavior() {
        let sampling = TranslationSamplingConfig(temperature: 0.7, topK: 1, topP: 1,
                                                 repetitionPenalty: 2)
        let token = MADLADTranslator.selectToken(MLXArray([Float(6), 4, -5, 1000]), vocabSize: 3,
                                                sampling: sampling, history: [0])
        #expect(token == 1)
    }

    @Test("EOS stops before append and maxTokens bounds the shared decoder loop")
    func tokenTermination() throws {
        let cases: [(Int, Int, [Int])] = [(2, 8, []), (99, 2, [2, 2]), (99, 0, [])]
        for (eos, maximum, expected) in cases {
            var calls = 0
            var yielded: [[Int]] = []
            let sampling = TranslationSamplingConfig(maxTokens: maximum)
            let generated = try MADLADTranslator.decodeTokens(
                sampling: sampling, eosTokenId: eos, decoderStartTokenId: 0, deadline: nil,
                step: { previous in
                    #expect(previous == (calls == 0 ? 0 : 2))
                    calls += 1
                    return 2
                }, didGenerate: { yielded.append($0) })
            #expect(generated == expected)
            #expect(calls == (eos == 2 ? 1 : maximum))
            #expect(yielded.count == expected.count)
            #expect(yielded.last ?? [] == expected)
        }
    }

    @Test("cancelled encoder admission fails before native work")
    func cancelledAdmission() async {
        let rejected = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try MADLADTranslator.checkAdmission(deadline: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(rejected)
    }

    @Test("a cancelled decode never starts its first step")
    func cancelledDecodeAdmission() async {
        let stopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            var calls = 0
            do {
                _ = try MADLADTranslator.decodeTokens(
                    sampling: .greedy, eosTokenId: 2, decoderStartTokenId: 0, deadline: nil,
                    step: { _ in calls += 1; return 3 }, didGenerate: { _ in })
                return false
            } catch is CancellationError {
                return calls == 0
            } catch {
                return false
            }
        }.value
        #expect(stopped)
    }

    @Test("cancellation inside synchronous decode waits for completion and discards its token")
    func cancellationDuringStep() async {
        let stopped = await Task.detached {
            var completed = false
            var yielded = 0
            var calls = 0
            do {
                _ = try MADLADTranslator.decodeTokens(
                    sampling: .greedy, eosTokenId: 2, decoderStartTokenId: 0, deadline: nil,
                    step: { _ in
                        calls += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        completed = true
                        return 3
                    }, didGenerate: { _ in yielded += 1 })
                return false
            } catch is CancellationError {
                return completed && calls == 1 && yielded == 0
            } catch {
                return false
            }
        }.value
        #expect(stopped)
    }

    @Test("stream-consumer cancellation stops before the next synchronous step")
    func cancellationAfterYield() async {
        let stopped = await Task.detached {
            var calls = 0
            var yielded = 0
            do {
                _ = try MADLADTranslator.decodeTokens(
                    sampling: .greedy, eosTokenId: 2, decoderStartTokenId: 0, deadline: nil,
                    step: { _ in calls += 1; return 3 },
                    didGenerate: { _ in
                        yielded += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    })
                return false
            } catch is CancellationError {
                return calls == 1 && yielded == 1
            } catch {
                return false
            }
        }.value
        #expect(stopped)
    }

    @Test("an expired deadline admits no synchronous decoder work")
    func expiredDecodeDeadline() {
        let deadline = ContinuousClock.now.advanced(by: .seconds(-1))
        var calls = 0
        #expect(throws: (any Error).self) {
            _ = try MADLADTranslator.decodeTokens(
                sampling: .greedy, eosTokenId: 2, decoderStartTokenId: 0, deadline: deadline,
                step: { _ in calls += 1; return 3 }, didGenerate: { _ in })
        }
        #expect(calls == 0)
    }

    @Test("encoder and every later step use one absolute deadline without resetting it")
    func sharedAbsoluteDeadline() throws {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(10))
        try MADLADTranslator.checkAdmission(deadline: nil, now: started.advanced(by: .seconds(100)))
        try MADLADTranslator.checkAdmission(deadline: deadline, now: started)
        try MADLADTranslator.checkAdmission(deadline: deadline, now: started.advanced(by: .seconds(9)))
        #expect(throws: (any Error).self) {
            try MADLADTranslator.checkAdmission(deadline: deadline, now: deadline)
        }
        #expect(throws: (any Error).self) {
            try MADLADTranslator.checkAdmission(deadline: deadline, now: started.advanced(by: .seconds(11)))
        }
    }

    private func cpuArgmax(_ logits: [Float]) -> Int {
        var index = 0
        var value = -Float.infinity
        for (candidate, score) in logits.enumerated() where score > value {
            value = score
            index = candidate
        }
        return index
    }
}
