# Product qualification contract

This is a separate, preliminary product gate. The existing twelve-cohort
`release-quality.json`, `verify()` API and CLI remain unchanged. Passing this
gate does not certify the broader release matrix. No production measurements
or independent reviews are supplied by this implementation: **UNVERIFIED**.

## CLI and native records

```
python3 scripts/verify-quality.py --product --revision FULL_40_HEX_GIT_SHA \
  --manifest /approved/corpus/manifest.json \
  --observations /approved/content-free-observations.json \
  product-batch.log [product-batch-2.log ...]
```

`--policy` defaults to `docs/benchmarks/product-quality.json` in product mode.
Product mode reads the approved manifest and content-free records, not audio,
model files, the installed app or private transcripts. Legacy mode keeps its
existing corpus-byte verification. Product collection must fingerprint the
approved inputs before and after execution.

Each batch uses the existing `SAIITY_QUALITY_SOURCE REVISION clean`,
`SAIITY_BENCHMARK_EVIDENCE JSON` and final `SAIITY_QUALITY_COMPLETE JSON`
markers. Completion uses the existing canonical `benchmark_evidence.digest`
(`json.dumps(sort_keys=True, separators=(",", ":"))`, UTF-8, SHA256).
The evidence header retains `schema: 1`, `corpus`, `models`, `hardware` and
`configuration`. Add `revision`, `sourceState: "clean"` and
`appBuild: {"version": STRING, "build": STRING, "binarySHA256": LOWERCASE_SHA256}`.
`hardware` retains model, arch, memoryBytes, macOS, osBuild, toolchain, swift,
sdk; add content-free `machineID` to distinguish identical Macs. Configuration
retains profile=`pipeline`, language=`auto`, chunkMs, runs, preview=`[false,true]`,
cleanup, cleanupModel, translation and target; add `powerMode`, `thermalState`,
`memoryPressure`. These conditions are explicit strings, never inferred.
Models include the actual ASR key, `cleanup:NAME` when model cleanup is used,
and the translation engine key when enabled. All values are file/tree SHA256.
The corpus binds the exact manifest SHA256 and each approved fixture checksum;
`corpusSHA256` is the canonical digest of `recordings`. No text enters the logs.

Emit `SAIITY_PRODUCT_BENCHMARK JSON` (or the existing `SAIITY_ASR_BENCHMARK`
prefix with these extra fields) for each run:

| Field | Contract |
| --- | --- |
| phase | `release_to_insertion` (historical name; does not prove insertion) |
| runID | Unique content-free identifier across all supplied batches |
| run | Positive integer within its batch |
| fixture, model, configuration | Match approved fixture, fingerprinted model and entire batch configuration |
| warmState | `warm`, `cold-start`, or `post-eviction`; actual lifecycle state |
| phraseSeconds | Positive recorded phrase duration; matches manifest fixture durationSeconds |
| preview | Strict boolean, separately grouped |
| deliveryEndpoint | `copied` or `paste-dispatched`; native code must never self-certify visible insertion |
| outputSHA256 | SHA256 of exact final delivered bytes, including separators, with no transcript text |
| phaseSeconds | Object with finite nonnegative `capture`, `modelLoad`, `nativeQueue`, `recognition`, `cleanup`, `translation`, `delivery`, `drain` durations |
| wer, missingWords, droppedAudioSeconds, languagePreserved | Scored source accuracy, zero lost audio and strict language-preservation result |
| scoring, cer, scoredLanguages | Existing reviewed source word/grapheme contract |
| outputWER, outputCER, outputMissingWords, outputLanguagePreserved, scoredOutputLanguages | Existing final source metrics for untranslated output |
| cleanup, translation, target | Match configuration |
| cleanupUnavailable, modelCalls, modelAccepted, modelFallbacks, rulesSkipped | Existing model cleanup outcomes/counts when enabled |
| wasTranslated, translationWER, translationCER, translationMissingWords, translationScoring, translationReferenceSHA256, targetLanguagePreserved, translationFailures, translationSkipped | Existing translated-output evidence; alternative reference/script bindings remain required where applicable |

The manifest keeps existing natural provenance, independent reference review,
known language sequence and scoring. Product fixtures additionally require
`condition` (`clean`, `difficult`, `noisy`) and positive `durationSeconds`.
Short is ≤10 s; medium is >10 and <30 s; long is ≥30 s. Reviewed clean EN/DE
need at least two clips and two speakers each. Repetitions cannot replace them.

## External observation file

A JSON array contains exactly one observation per supplied runID. No transcript,
recording, screenshot or credentials belong in this file. Each entry has:

```
{
  "runID": "opaque-run-id",
  "outputSHA256": "exact-final-output-lowercase-sha256",
  "evidenceSHA256": "canonical-digest-of-entire-batch-header",
  "endpoint": "visible-insertion",
  "observer": {"identity": "content-free-observer-id", "independent": true,
               "method": "external-accessibility"},
  "targetApp": "destination-bundle-id",
  "physicalInputObserved": true,
  "compositorHiddenObserved": true,
  "inputStoppedObserved": true,
  "durationsSeconds": {
    "captureStart": 0.0, "releaseToEndpoint": 0.0,
    "stopToCompositorHidden": 0.0, "stopToInputStopped": 0.0
  },
  "qualityReview": {
    "reviewed": true, "independent": true, "reviewer": "reviewer-id",
    "outputSHA256": "same-exact-output-sha256",
    "evidenceSHA256": "same-entire-batch-header-digest",
    "meaning": true, "names": true, "numbers": true, "negation": true,
    "omissions": true, "naturalness": true
  }
}
```

Numbers above explain shape only and are not measurements. Allowed observer
methods are `external-accessibility`, `external-video`, `human-observation`.
Observation, observer, review, external duration and native phase-duration
objects are closed schemas: use exactly the listed fields. Text/comment payloads
and unrecognized extra fields are rejected. Identities and destination app IDs
must be nonempty, content-free identifiers; the verifier cannot infer whether an
arbitrary identifier contains personal information.
`endpoint` is exactly `copied`, `paste-dispatched` or `visible-insertion`.
Visible insertion requires native `paste-dispatched`, observation in a real
target app and exact final-byte binding. In-memory clipboard callbacks, posted
Paste events, application state, layout probes and simulated input cannot
assert external physical/compositor evidence. Capture starts at actual physical
shortcut input and ends at the first accepted microphone samples. Stop timings
start at actual Stop input; compositor disappearance and input cessation are
independently observed. `drain` is native completion, never input cessation.
Release-to-endpoint starts at actual release and ends at the stated endpoint.

Every observation and semantic review binds the header digest and exact output
hash. Hashes prevent accidental evidence mixing; this unsigned local format
does not authenticate the truthfulness of an observer. Authorized independent
collection and review remain necessary. The verifier cannot manufacture them.

## Qualification and reporting

Policy `requiredCases` declares explicit source cohort, ASR model and processing
configuration subsets; full measured configuration remains bound and groups
separately (only batch `runs` is excluded from grouping). Preview on/off each
requires at least 50 warm **short, clean, visible-insertion** observations and
five `cold-start` plus five `post-eviction` observations per required case.
Both approved clips and speakers must appear in each group. Cold-start means
a fresh process with no retained model; post-eviction means a confirmed existing
pool eviction, not a first iteration relabelled cold. Cold timings are reported
without applying warm targets. There is no claim of a statistically stable
population p95 from 50 preliminary repetitions.

Summaries separate warmState, duration bucket, condition, source cohort, model,
full configuration, preview and observed endpoint. Copy and paste-dispatch
summaries never satisfy visible-insertion coverage. Difficult/noisy and
medium/long groups never dilute short clean tails or clean accuracy. They are
reported separately; zero dropped audio and independent semantic review remain
mandatory for all submitted observations. No fast fallback can qualify a model
cleanup/translation path. Model-cleaned cases require actual accepted model
work in each group; translated cases require completed translation and exact
reviewed target references in every run.

For warm short clean visible groups, nearest-rank p95 targets are captureStart
≤0.150 s, releaseToEndpoint ≤0.700 s (rules), ≤1.2 s (model cleanup), ≤2.5 s
(qualified translation pair), stopToCompositorHidden ≤0.100 s and
stopToInputStopped ≤0.250 s. Clean EN/DE source WER is ≤0.05 on **every** run;
untranslated final WER is also ≤0.05. Missing source/final words and lost audio
must be zero. Translated output keeps the existing ≤0.25 WER ceiling plus zero
omissions and all critical review checks; this is a bounded pair qualification,
not an EN/DE ASR threshold transplanted into other languages.

Destination app IDs also group separately: observations in different apps cannot
pool toward the minimum. Different machine identities, hardware/toolchains, app
binaries, corpora or overlapping model fingerprints cannot be combined. The
initial policy explicitly covers Nemotron 2240 ms rules/model source EN/DE and
rules-only Hy-MT2/MADLAD EN→DE and DE→EN. A measured configuration (including
cleanup model choice and power/thermal/pressure conditions) qualifies only its
own groups. Other tiers, models, language pairs and combined model-cleanup plus
translation require their own explicit cases; no broader claim follows here.

Missing observations, stale/mixed binding, missing reviewers, duplicate runs,
unmet coverage or failed budgets return nonzero with `UNVERIFIED`. The checked-in
policy remains `status: "unverified"`; it declares targets, not measured success.
