# Model options and performance implementation plan

> For workers: use subagent-driven-development where routing is verified. Main owns all serial Swift tests, app builds and native inference.

**Goal:** Add Gemma 4 E2B/E4B cleanup, TranslateGemma 4B translation and commercial Granite Speech 5.0 English recognition choices, and implement the ten accepted findings in `build/performance-audit-20261014/report.md`.

**Architecture:** Extend the existing native model catalogue, backend adapters, controller, inference ownership and transcript store. Preserve validated source recovery and active native ownership. Use the smallest complete changes; do not introduce another manager, database or telemetry system.

**Tech stack:** Swift/AppKit/SwiftUI, CoreML/MLX/llama where the exact model architecture is supported, existing downloader and registry, Swift Testing and the existing Python release verifier.

## Global constraints

- Work in the existing `/Users/enrico/Documents/GitHub/saiity` checkout on `codex/models-performance-20261014`, starting at `6be8b154f68ac240c178d1f644fd48b39a7f09de`. Preserve all existing/recovery artifacts and subsequent unrelated changes.
- The human accepted the audit proposals and explicitly authorized these local implementations. No additional design approval is needed for their routine implementation choices.
- New options must have actual runtime adapters and truthful supported-language/memory/availability information. A catalogue label alone is not an implementation. Keep the existing choices and explicit user selection; do not change defaults silently.
- Models download only through the existing explicit app controls. This implementation does not authorize collecting recordings, accessing private transcripts, downloading weights for development, changing permissions, replacing installed apps, committing/pushing, publication or deployment.
- Use Chrome Use for official model/dependency website research and Computer Use for desktop UI. Native CLI tools remain appropriate for source/build work.
- Every worker must use verified `sub2api/gpt-6.1-sol`. Main checks the actual worker rollout's `turn_context.model` before implementation. Workers do not run Swift builds/tests/native inference.
- Main runs serial relevant checks through `/Users/enrico/.codex/bin/codex-task`; disposable products use `CODEX_TASK_TMP`, retained outputs use `CODEX_TASK_ARTIFACTS` or documented `build/` outputs. Reuse package caches and do not duplicate an active build.
- Preserve sample coverage, Unicode/language boundaries, numbers/names/negation, secure-field/focus checks, original-text recovery, optional memory-only history, bounded queues and native drain acknowledgement.
- Existing independent review/natural-speech/device/calibration gates remain explicit. Code/synthetic evidence cannot certify physical keyboard, speech accuracy, compositor speed or insertion into another app.
- Preserve the paused `continue-saiity-desktop` automation and all other schedules.

## Task 1: Honest product qualification and timings — audit 1

Files: `Diagnostics.swift`, `DictationBenchmarking.swift`, `TextInsertion.swift`, existing benchmark tests, `scripts/verify-quality.py`, `docs/benchmarks/` and `docs/release-checklist.md`.

- [x] Add tests that distinguish copy completion, paste dispatch and externally verified insertion; retain old record parsing compatibility.
- [x] Add an explicit short-dictation product policy with cold/warm, phrase duration, preview, cleanup, translation, outcome and enough repetitions to estimate the tail. Keep the existing twelve-cohort semantic review obligations unchanged.
- [x] Split timing summaries by cold/warm and outcome; preserve content-free run IDs and model counts.
- [x] Require current source/hardware/model fingerprints and externally supplied visible-insertion/physical UI evidence for applicable product gates. Missing evidence fails honestly.

Proposed product targets accepted for qualification: warm capture p95 150 ms; short source/rules release-to-visible-insertion 700 ms; model-cleaned 1.2 s; translated pairs 2.5 s; Stop-to-hidden 100 ms; Stop-to-input-stopped 250 ms; clean reviewed EN/DE WER 5%; zero lost audio and zero critical semantic changes. These are gates to measure, not claimed results.

## Task 2: New model choices and real runtime paths

Files: `LocalModels.swift`, `TranslationEngine.swift`, `EngineLanguages.swift`, `ASREngine.swift`, `Translators.swift`, existing native model adapters/catalogue/UI/download/health paths, `Package.swift`/resolved dependencies when necessary, existing catalogue/language/runtime tests and localized strings.

- [x] Verify official model files, formats, commercial licensing and pinned runtime support. Gemma 4 uses a different architecture and chat framing; the current llama binary exposes Gemma 3/3n but no Gemma 4 symbol. Granite is absent from current Swift speech adapters. Resolve those concrete runtime requirements without installing a model.
- [x] Add Gemma 4 E2B and E4B as separate cleanup choices with compatible quantized files and bounded generation. Keep Gemma 3 1B/4B and custom models.
- [x] Add TranslateGemma 4B as a translation specialist with its actual translation template and language mapping. Preserve mixed regions, variants, validation and source fallback.
- [x] Add the Apache-2.0 Granite Speech 5.0 470M TurboCTC model as an English recognition choice. Never substitute the non-commercial checkpoint. Implement the native feature frontend/decoder through a supported runtime, not a misleading selector.
- [x] Cover selection persistence, missing/corrupt model states, explicit downloads, removal/quiescence, settings and diagnostics. Keep unsupported/runtime-unverified claims explicit.

## Task 3: Caret-aware bounded delivery — audit 3

Worker owns `TextInsertion.swift` and `TextInsertionTests.swift`; main coordinates timing record integration.

- [x] Reproduce beginning/middle/end/selection separator mistakes in tests using the existing injectable target/focus paths.
- [x] Use actual selected range and bounded surrounding AX text. Set a messaging timeout, avoid full-document value reads, preserve secure target and original focus checks.
- [x] Check Unicode, absent AX data, timeout/copy recovery and posted-paste status.

## Task 4: Immediate capture and incremental authoritative decoding — audits 2 and 4

Files: `DictationController.swift`, `DictationMicrophoneCapture.swift`, `DictationTranscription.swift`, `StreamingASRBackend.swift`, `WhisperDictationBackend.swift`, existing controller/capture/segmentation tests.

- [x] Add delayed-preparation tests proving samples are captured from the authorized press and retained when release precedes model readiness; cancellation never reopens capture.
- [x] Start bounded validated-format capture before model preparation. Replay the buffered samples in exact order to the selected recognition path where required.
- [x] Extend the existing segmentation logic to identify only stable completed regions during capture. Retain a potentially mergeable tail and the required hard-cut lookahead.
- [x] Decode authoritative completed regions once while recording under the backend's existing ownership. Release finishes the unresolved tail and merges previously accepted regions; previews remain provisional.
- [x] Prove complete sample coverage, no native overlap, limit/failure/cancel behavior and unchanged region/text/language ordering with delayed fake decoding.

## Task 5: Model reuse under bounded memory — audits 5 and 6

Files: `AppDelegate.swift`, `ASRBackendPool.swift`, `CaptionSessionResources.swift`, `DictationCleanupSession.swift`, `TranslationRuntime.swift`, `MemoryPolicy.swift` and existing lifecycle tests.

- [x] Add load-count tests for identical/different captions/dictation model keys and switching during preparation/teardown.
- [x] Reuse existing ASR pool ownership for identical engine/tier/configuration keys. Retain independent owners when settings differ; release inactive resources safely under pressure.
- [x] Remove unnecessary text-model prepare/retarget/reload work. Reuse an exact existing loaded model where both tasks support it; any dual-model retention must remain bounded, pressure-aware and separately qualified.
- [x] Preserve active native leases and source recovery during pressure or a settings change. Add content-free residency/load evidence; do not claim memory gains without measurement.

## Task 6: Total deadlines and native greedy decoding — audits 7 and 8

Files: `LocalGeneration.swift`, `TranslationEngine.swift`, `DictationCleanupSession.swift`, `AppDelegate.swift`, `Translators.swift`, repository-owned native wrapper/patch and existing generation/gate tests.

- [x] Add queue-delay/load/retry/region tests with an injected shared deadline; exhausted runs return the safe baseline/source and cannot insert stale results.
- [x] Carry one post-release deadline through queue admission, preparation, cleanup, translation and retries. Stop still closes UI/capture before draining accepted work.
- [x] Implement MADLAD greedy argmax on-device and transfer one scalar; preserve vocabulary bounds, Float32 and tie/termination behavior. Maintain this in a pinned upstream or repository-owned dependency patch, never by editing `.build/checkouts`.
- [x] Put cancellation/deadline checks inside the native decode loop where supported and retain native completion ownership. Outer timeouts cannot release running state.

## Task 7: Cancelled searches and scan-resistant cache — audits 9 and 10

Worker owns `SegmentCache.swift`, `TranscriptStore.swift`, `TranscriptStoreTests.swift`. Main owns the `SettingsPages.swift` search UI integration.

- [x] Add a scaled four-session/three-entry cache regression plus stale edit/delete and cancellation cases.
- [x] Use existing store/cache methods for scan admission that preserves useful entries instead of evicting the entire next pass. Keep the 32 MiB bound and avoid partial decoded cache values.
- [x] Propagate parent cancellation to detached search and stop superseded session/segment loops. Reuse the reader's cancellation-handler pattern.
- [x] Main runs synthetic 100/500-session and over-budget checks without user-library access; record read/decode/hit counts, completion and memory bounds.

## Task 8: Integration, verification and delivery

- [x] Review each bounded change against its accepted audit requirement, native lifecycle and privacy constraints.
- [x] Main observes intended failures before nontrivial fixes, runs affected serial checks, then one complete supported suite after integration. Do not repeat unchanged passing checks unnecessarily.
- [x] Verify localizations, Python/shell checks and package/resource/signature checks. Build a hook-free local app using explicit disposable/persistent paths, preserving previous bundles.
- [x] Use native synthetic UI qualification when available; retain the actual human shortcut workflow and natural speech/device gates as unverified unless new evidence satisfies them.
- [x] Record final changed files, test/build evidence, remaining gates and artifact paths in `.superpowers/sdd/progress.md`. No commit, installation or publication.

## Ownership and recovery

Main: native model/runtime integration, controller/deadlines/model reuse, settings/localizations, diagnostics/qualification, all Swift tests/builds/native work, review and delivery.

Huygens (`01a13baf-9847-7472-99f7-b25d6de26d19`): task 3, exact rollout model verified as `sub2api/gpt-6.1-sol`, high effort. Preparing tests; main runs RED.

Gauss (`01a13bb1-ac4d-7ea0-b799-9510e13861ad`): task 7 store/cache files, same explicit model pending main metadata verification. Preparing tests; main runs RED.

When resuming, read this plan, the durable ledger, worker status/model metadata, Git state and active processes first. Resume the first incomplete item; never restart active native work or duplicate worker ownership.

## Local verification status — 16 October 2026

Tasks 1–8 are complete for the authorized local implementation and delivery scope in the current uncommitted branch. Their checkmarks describe local implementation and synthetic verification. They do not close the natural-speech, semantic-review, device or calibrated-performance release gates from this plan or the 9 October language-quality plan.

| Check | Evidence |
| --- | --- |
| Final supported Swift suite | 954 tests in 89 suites, zero issues, 13.826 seconds; `/private/tmp/codex-task.3sr6jx3h/artifacts/audit-integration-tests.log` |
| Final affected model/removal/cache/pipeline suite | 132 tests in 6 suites, zero issues, 3.308 seconds; `/private/tmp/codex-task.bu7aatzq/artifacts/audit-integration-tests.log` |
| Integration regression failures observed before fixes | 53 tests / 41 issues, then cancellation/download admission 2 tests / 11 issues; retained `v48gj14m` and `h6wg175f` task artifacts |
| Whisper preparation regression failures | 2 tests / 5 issues, 0.126 seconds; `/private/tmp/codex-task.2a2fq7s7/artifacts/audit-integration-tests.log` |
| Idle eviction and Forget unload regression failures | 1 test with 2 cases / 2 issues, 0.035 seconds; `/private/tmp/codex-task.qqj5iowj/artifacts/audit-integration-tests.log` |
| Final source review | `build/performance-audit-20261014/model-integration-final-review.md`; independent source review on the verified worker route, with no open concrete defect in its bounded scope |
| Compiler, native-library, license, resource and script manifest | 206 inputs; `/private/tmp/codex-task.oziu3fx8/artifacts/compiler-input-sha256.txt`; tracked worktree patch retained beside it |
| Python gates | Historical 37-test verifier and 15-test collector passes remain documented in their worker reports. Their old temporary logs are unavailable now; frozen unchanged suites were not rerun or represented as fresh evidence. |
| Packaging | Final hook-free app and DMG passed release, dependency, resource, deep-signature, isolated-home launch, 32 native smoke checks and fresh read-only mount verification; `/private/tmp/codex-task.xkl_6y8r/artifacts`. The earlier `x_bvae8c` candidate remains preserved. |
| Input stability after packaging | All 206 manifest entries matched; shell syntax, localization units and scoped diff whitespace passed. `/private/tmp/codex-task.3x6ku89r/artifacts` |

The follow-up fixes keep independently admitted Whisper preparation out of removal until its actual return, route legacy Whisper deletion through the shared guarded transaction, and retain pending native unloads until completion. The small Whisper cache waits for all currently pending unloads during invalidation. A stalled native unload can therefore delay deletion; an outer timeout must not release the owner early.

Product qualification remains **UNVERIFIED**. No approved natural recordings, independent source/target/semantic review observations, real target-app insertion, physical shortcut workflow, compositor/input-stop observations, hardware calibration or new model-weight inference was supplied by these checks. Granite cancellation still polls only at native entry; linked ABI checks are not encoder execution. PCM backlog bounds do not establish bounded lifetime caption text, physical footprint or energy use. No measured speedup or recognition/translation-quality gain is claimed.

The local deliverables remain ad-hoc signed and unnotarized. No installed app replacement, permission change, commit, push, publication or automation update is part of this work. Preserve the paused recovery automation and prior candidates.

### Final local artifacts

- App: `/private/tmp/codex-task.xkl_6y8r/artifacts/Syllivra.app`, version `2.7.0-models-performance-local`, build `226`.
- Executable SHA-256: `f6cbb17ea537c298f5dacbdfd1fe6e794d9588a2d4d26059deecc17cff69e7da`.
- DMG: `/private/tmp/codex-task.xkl_6y8r/artifacts/Syllivra-models-performance-local.dmg`, 28,261,299 bytes.
- DMG SHA-256: `13fa3c8cd834bb4e28150cdfd58453baef2aeadf132e5df2997980530f0bbca6`; retained `SHA256SUMS.txt` is beside the DMG.
- Build, release/signature/resource/dependency, isolated-home, smoke and DMG verification logs are retained beside the deliverables. The verification mount was detached and successful wrappers cleaned only their owned scratch.

### Durable candidate preservation — 18 October 2026

The final app, DMG and packaging logs are also preserved at `build/candidates/2.7.0-226/`, outside macOS temporary storage. The DMG in the original temporary directory had been renamed to `Syllivra-models-performance-local Kopie.dmg`; its bytes matched the recorded final SHA-256 before copying it under the original filename. The original temporary files remain untouched.

The preserved `SHA256SUMS.txt` uses relative paths for the DMG and app executable. `SHA256SUMS.original.txt` retains the original checksum file verbatim. Both copied hashes, the app's files and symlinks, copied logs and deep signature were verified. The final supported and affected test logs, the 206-entry input manifest and a fresh successful input-hash verification are retained alongside the candidate. Tests and builds were not rerun for preservation or local commits.

Local commits on `codex/models-performance-20261014` preserve the reviewed implementation in four groups: model runtimes; capture, delivery and deadlines; model reuse, cleanup and cache/search; qualification tooling and documentation. The generated session checkpoint, build outputs and shared caches remain outside those commits. This preservation does not qualify real speech, physical shortcuts, visible insertion or measured performance, and does not authorize a push, tag, release, notarization or installation.
