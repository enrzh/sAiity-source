# Repository-owned MADLAD target

Sources come from `https://github.com/soniqo/speech-swift` at revision
`37c99dd856cfacfe952b2e48ecdb3c9dedc77625`:

- Six files from `Sources/MADLADTranslation`; `import MLXCommon` was removed
  from MADLADModel, MADLADTranslator and MADLADWeightLoading. The translator
  additionally carries the local greedy/cancellation/deadline changes below.
- `Sources/MLXCommon/WeightLoading.swift`, copied byte-identically for
  CommonWeightLoader and its error declarations.
- `Sources/MLXCommon/PreQuantizedEmbedding.swift`, copied byte-identically.
- `Sources/MLXCommon/QuantizedMLP.swift`, copied byte-identically because the
  unchanged full WeightLoading file references both QuantizedMLP and MLP.

`LICENSE` is the upstream Apache-2.0 license, including its copyright notice.
No model assets, complete additional source targets, or dependency checkout
modifications are included. TranslationSamplingConfig, greedyArgmax and
sampleWithTemperature already live in the MADLAD files and were not duplicated.

The local module name is `SaiityMADLAD`. Public model, tokenizer,
configuration and loading APIs retain their upstream names and signatures.
The translation, generation and streaming methods add an optional
`deadline: ContinuousClock.Instant? = nil` argument; existing ordinary calls
continue to work. Application callers must pass their shared absolute deadline
to enforce it inside native generation.

The local files import AudioCommon, MLX, MLXNN, MLXFast and Tokenizers;
Foundation and os.log are system modules. MLXCommon has no public product,
and the local target now requires no import or dependency on that module.
The added helper files depend only on Foundation, MLX, MLXNN and one another;
they do not pull in any additional private speech-swift target. Main wires
the direct products against existing pins, including MLXRandom as specified
in main's integration plan. Exclude this README and LICENSE from the local
source target.

## Local changes and verification boundary

After MAIN observed compile RED for missing selectToken, decodeTokens and
checkAdmission, the translator received those three internal helpers. Both
production decoder paths share token termination, cancellation and absolute
deadline admission. Encoder and decoder evaluation complete synchronously
before cancellation/deadline errors release the corresponding local state.
AsyncThrowingStream termination cancels the actual producer task, whose
closure retains the translator while native work finishes.

Greedy selection casts to Float32, slices the configured vocabulary on MLX,
maps NaN scores to negative infinity to preserve the pinned CPU loop's ignored
NaNs, and reads one argmax index scalar. Positive-temperature sampling retains
the pinned CPU helper and its score transfer. The pinned greedyArgmax and
sampleWithTemperature functions, sampling configuration, loaders, tokenizer,
model and license remain unchanged. Stream fragments still decode the full
accumulated token sequence before emitting the new suffix.

Deadline exhaustion throws the existing inferenceFailed error with reason
`Translation deadline exceeded`; cancellation throws CancellationError.
No outer timeout releases an active evaluation. A long synchronous evaluation
can still exceed the deadline before control returns to the next check.

The active synthetic tests are owned by MAIN at
`Tests/sAiityTests/MADLADNativeLoopTests.swift`; the original external draft
remains in `build/performance-audit-20261014/madlad-native-tests.swift`.
This worker ran no Swift/native checks. Actual assertions, stream termination,
Float32/tie/NaN equivalence, speed, memory and natural translation remain for
MAIN's serialized native checks and qualification. Compile RED is not runtime
acceptance evidence.
