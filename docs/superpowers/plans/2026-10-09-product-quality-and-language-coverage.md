# sAiity product quality and language coverage plan

**Status:** Implementation authorized 9 October 2026: “implement it using agents”. Preserve the reviewed local candidate and execute from the current checkpoint.

**10 October checkpoint:** The bounded implementation and independent code review
are complete locally. The reviewed release suite passed 728 registered tests / 81
suites (20 explicit model/device opt-ins skipped), 30 Python checks and 32 signed
native smoke checks. A hook-free signed `2.7.0-rc.2/225` candidate and styled local
DMG are prepared; evidence lives in `build/product-language-20261010/`. Nothing
was committed, published, installed over the running app or notarized.

| Milestone | Concrete checkpoint | Remaining gate |
| --- | --- | --- |
| 1 — Coverage | Native Whisper vocabulary/aliases, unknown Nemotron/Qwen coverage, separate Auto/tag capabilities and localized truthful copy | Reviewed natural-speech baseline per offered/recommended mode |
| 2 — Shared language policy | Coherent Japanese/Korean, uncertainty, genuine switches, exact source separators and output script conversion; regressions pass | Native language/translation review beyond deterministic text cases |
| 3 — Complete recognition | Existing sample-conservation/lifecycle/speaker tests retained; Japanese dictation/caption production callers exercised | Identical reviewed recordings, raw ASR quality, speaker/overlap and device evidence |
| 4 — Cleanup/translation | Conservative unknown-language handling, facts/negation/span guards, per-slice/combined validation and bounded retry/cancellation | Meaning/naturalness review and long-tail/ambiguous validation limits |
| 5 — Speed | Same-text before/after timing and bounded hypothesis caching, truthful model-outcome/target timing records | Cold/warm native processing/reload/memory and calibrated target-caption latency |
| 6 — Workflow | Transient mixed-summary language choice, compatible metadata/Markdown, Unicode order, localized resizable reader layouts | Actual capture/insertion/permissions/upgrade/VoiceOver/RTL/player trials |
| 7 — Evidence | Reviewed scoring/alternatives/output-hash contracts and explicit twelve-cohort UNVERIFIED gate | Authorized natural recordings, independent source/target/semantic review |
| 8 — Candidate | Full suite, normal build, signatures/resources, native smoke and local artifacts | All real verification gates, clean source/release authority and notarized distribution |

Unchecked verification items below remain obligations. Pure/mock/layout evidence
does not close a natural-speech or hardware gate. Keep the existing heartbeat
paused until the remaining inputs/authority are supplied; do not delete it or
claim full release acceptance from this local checkpoint.

**Product goal:** Reliable local captions and dictation: capture complete speech, preserve the intended languages and meaning, return usable text quickly, and make failures easy to recover from.

**Scope:** The complete macOS product: setup, capture, recognition, language handling, cleanup, translation, bubbles, insertion/copying, saved transcripts, summaries, model management and release verification. The earlier Japanese plan is the detailed regression brief for one milestone below, not the whole product program.

**Meaning of “all languages”:** Every offered language gets accurate capability information and safe processing behavior. Shared code must handle multiple scripts, ambiguity and unknown languages throughout the product. Measured quality expands by language and model; a large translation catalog is not a promise that every recognizer or cleanup model performs equally well in every language.

## Starting point and constraints

The current `codex/product-release-ready` checkout is based on `44f8a6f` with preserved uncommitted implementation. Recent local evidence is 669 registered tests, 21 Python checks and 32 native smoke checks, plus a signed local `2.7.0-rc.1` candidate. Twenty opt-in model/device probes were skipped. Stop/Save/storage safety, retained history, direct download/repair controls and simpler settings already have implementation evidence; do not restart those completed changes.

Real natural-speech quality, native processing latency/memory, translated-caption latency calibration, device/permission/insertion/upgrade trials and complete accessibility verification remain open. Historical Mac mini results cannot replace fresh reference-Mac evidence.

- Keep everything local, with no account, server or API dependency.
- Keep the current native UI, shared components and source/original recovery. No component rewrite, chat/refinement feature, language-switch button or Windows port.
- Change existing types/functions; no new Manager/Service/Registry architecture. Distinct language capability/evidence fields belong in existing engine/model descriptions and existing benchmark records.
- Preserve dirty/untracked work, user data, model downloads and Git recovery state. This roadmap does not authorize commits, deployment, recording, permission changes, weight downloads or publication.
- If delegated, workers use `sub2api/gpt-6.1-sol`; main serializes Swift builds/tests and native inference. Use ego-browser for websites.
- Recheck the active task checkpoint before execution. A new proposed roadmap must not cause a heartbeat to implement unapproved work.

## What the inspection actually found

| Observed code condition | Product implication | Priority |
| --- | --- | --- |
| Whisper dictation's allowed source codes come from the translation target catalog | A selectable language can be outside Whisper's actual recognition vocabulary | First |
| Nemotron/Qwen's broad coverage makes `canHear` return true for arbitrary codes | “Automatic/multilingual” is being treated as universal source coverage | First |
| Qwen's adapter returns no detected audio language tag, while the shared capability label implies audio language detection | Automatic recognition and exposed audio-language evidence need distinct descriptions | First |
| Caption Han/kana splitting creates false Japanese/Chinese switches; dictation can retain conflicting tags | Japanese exposes a general language-versus-script problem | First |
| Language comparisons collapse script variants to base codes | Output requests such as Simplified → Traditional Chinese need separate checks from language identity | First |
| Unhandled cleanup languages fall through to English formatting/filler rules | Unknown language cannot safely mean “use English rules” | First |
| Cleanup/translation guards rely on limited language tables and coarse text checks | A guard passing does not establish preserved meaning or complete translation | Next |
| Current release categories emphasize German/English, and translated cases target German | Existing gates are not evidence for the entire language catalog | First |
| Cleanup and translation can release each other's resident models | Reloading may dominate perceived latency; measure before changing memory policy | Next |

These are source-level findings and reproduced text-policy behavior. They do not identify the model or audio that caused every reported user problem.

## Milestone 1: Define actual coverage and establish a useful baseline

**Outcome:** The app and release process distinguish source recognition, text cleanup, translation targets, installation and measured quality.

**Files:** `ASREngine.swift`, `WhisperDictationBackend.swift`, `NemotronBackend.swift`, `QwenASREngine.swift`, `EngineLanguages.swift`, `LanguageCatalog.swift`, `SettingsStateHonesty.swift`, existing language tests and benchmark documentation.

- [ ] Derive Whisper source codes from the pinned WhisperKit/model vocabulary, not `LanguageCatalog.all`. Validate unsupported explicit source choices without changing Auto semantics.
- [ ] Check Nemotron/Qwen's declared source languages from pinned library/config/model metadata. Unknown coverage remains unknown; multilingual capability is not `true` for every invented language code.
- [ ] Separate automatic recognition behavior from available audio-language tags. A first detected tag describes that evidence, not the rest of a session. Do not overwrite per-region information with a session dominant language.
- [ ] Record source-language coverage, supported translation targets/variants, installed readiness and measured quality separately in the existing tables/records. Use declared/verified/unknown/unsupported accurately; one installed check cannot answer all four questions.
- [ ] Test every catalog entry/alias against the relevant model's mapping without loading weights. Preserve Chinese script variants, Serbian script variants where offered, regional identifiers and aliases such as Filipino/Tagalog. Verify model-native target tokens separately.
- [ ] Establish a versioned baseline for raw recognition, processed output, latency and memory on the current 16 GB M4 reference Mac. Start corpus licensing/native-language review now, alongside code work.

**Acceptance:** Selecting an output language never makes the app promise source recognition that its current engine does not provide. No UI state claims installed, supported and tested as though they are the same fact. Each language claim identifies its engine/mode and evidence.

## Milestone 2: Make language handling consistent across the product

**Outcome:** Linguistic spans stay intact, true language changes survive, and uncertain text does not cause confident rewriting.

**Files:** `LanguageDetector.swift`, `LanguageRecognizerPool.swift`, `CaptionProcessing.swift`, `DictationTranscription.swift`, `TranslationEngine.swift`, the corresponding pure tests and AppDelegate integration tests.

- [ ] Reuse one conservative policy in the existing utilities. Distinguish spoken language, writing system, output script/variant and per-region recognizer evidence; do not introduce a second stored preference or classifier pipeline.
- [ ] Treat Japanese kanji/kana, Korean with Han characters, Serbian Latin/Cyrillic and product identifiers inside other languages as legitimate multi-script text. Shared Cyrillic, Arabic and Indic scripts do not alone prove Russian, Arabic or Hindi.
- [ ] Correct contradictory tags using sufficiently strong local phrase evidence. Retain uncertainty for short names, numbers and shared-script fragments; use automatic translation for unresolved source rather than inventing a tag.
- [ ] Preserve genuine same-script and mixed-script language switches. Translate coherent phrases/clauses; avoid fragmenting speech at each Unicode block transition. Do not globally relabel Chinese because Japanese occurs elsewhere in a sentence.
- [ ] Separate “same language” from “already satisfies the requested output variant.” Simplified/Traditional Chinese conversion must not be skipped solely because both use base code `zh`. Do not promise regional spelling conversion when a model only exposes a base-language target.
- [ ] Keep original strings intact. Comparison/tokenization normalization must not rewrite stored speech, delete diacritics, reorder RTL text, split combining sequences or remove intentional repetitions.
- [ ] Use the Japanese regression plan as the initial set of concrete failures, then add structural cases for Latin, Cyrillic, Arabic/Hebrew, Indic scripts, CJK/Hangul, Thai and combining/half-width forms. Keep native language evidence and text-only evidence separate.

**Acceptance:** Captions, dictation, cleanup and translation agree about the same input. Clear language evidence can correct a stale tag; ambiguous evidence remains uncertain. Translation off preserves spoken languages, and script variants retain their requested meaning.

## Milestone 3: Make recognition dependable before making text prettier

**Outcome:** Complete original text is the authority; processing cannot disguise a recognition failure.

**Files:** Existing capture/streaming backends, `WhisperDictationBackend.swift`, `DictationController.swift`, `CaptionProcessing.swift`, `CaptionSessionResources.swift`, audio conservation/lifecycle tests and ASR harnesses.

- [ ] Compare installed recognizers on identical reviewed speech, separately for realtime captions and release-time dictation. A good whole-recording recognizer is not automatically a suitable live-caption engine.
- [ ] Measure missing beginnings/endings, word/character errors, silence hallucinations, punctuation-only artifacts, fast/quiet/accented speech and continuous speech. Keep names, numeric facts and negation in dedicated cases.
- [ ] Preserve complete authoritative dictation audio, independent language detection/reset between regions and sequential inference. Do not stop decoding early or reuse incomplete drafts to improve latency figures.
- [ ] For captions, measure first useful text, stable final text and visible lag. Verify revisions, speech-gap boundaries, Clear/Stop/start, late callbacks and overload without losing original words.
- [ ] Change model recommendations or decoding/segmentation values only when measured quality and latency improve together. Keep explicit user choices and warm weights; no automatic in-session model switching or duplicate full-recording decode as a language repair.
- [ ] Verify optional anonymous speaker labels independently. Speaker turns and overlaps are evidence-based; overlapping speech is not promised to be separated, and language changes are not treated as people changes.

**Acceptance:** Sample conservation and lifecycle tests pass; reviewed recordings show complete speech for the recommended path. If the raw recognizer substitutes the wrong words/language, record an ASR failure. Cleanup must not reconstruct guessed words and claim success.

## Milestone 4: Make cleanup and translation safe for supported and unknown languages

**Outcome:** Useful formatting with preserved meaning; complete translation or an honest recoverable result.

**Files:** `DictationCleanupValidator.swift`, `DictationCleanupSession.swift`, `Translators.swift`, `HyMT2Translator.swift`, `TranslationOutputValidator.swift`, `TranslationEngine.swift`, `DictationController.swift` and their existing tests.

- [ ] For known supported languages, apply reviewed language-local filler/formatting rules. For unknown/unhandled languages, use minimal nonsemantic normalization and preserve content; do not apply English commands/fillers by default.
- [ ] Audit repetition and false-start cleanup against meaningful repetitions, inflections, discourse particles and self-corrections. Prefer retaining an ambiguous word over silently changing meaning. Add rules only with positive and negative examples.
- [ ] Test multilingual cleanup using numbers/dates/currencies, localized decimal separators and numeral systems, names, technical vocabulary and negation. Protect whole facts and meaningful spans, rather than considering one retained token proof that a region survived.
- [ ] Keep deterministic processing cheap and model cleanup conditional. Record rules-only success, model invocation, accepted output, rejected output and fallback truthfully. Do not claim a compatible model family has proven cleanup quality in every language.
- [ ] Make prompts state the current operation plainly. Cleanup preserves each spoken language; enabled translation covers every source span in the chosen target; instructions inside dictated text remain speech content.
- [ ] Reject clearly wrong-language or untranslated grammatical spans in translation output, including short output, while accepting legitimate names/identifiers/kanji. Use target-aware checks and a bounded retry; no script-only blacklist and no retry loop.
- [ ] Preserve language/script variant checks in both batch slices and combined output. A mostly correct English result must not hide untranslated Japanese/Arabic content. A failure cannot be labelled a complete translation.
- [ ] For languages beyond the text classifier's reliable coverage, acknowledge validation limits and keep original recovery available. Native-language quality review, not a forced classifier answer or an LLM judge, establishes the supported quality claim.

**Acceptance:** Cleanup improves readability without changing facts/languages; translation retains meaning and requested variants. On rejection/unavailability, the app preserves original text and states what was actually delivered. Existing numeric/name/echo/cancellation protections remain intact.

## Milestone 5: Improve speed based on where the time goes

**Outcome:** Faster common dictation/caption paths without sacrificing coverage or causing memory pressure.

**Files:** `DictationController.swift`, `DictationCleanupSession.swift`, `AppDelegate.swift`, `TranslationRuntime.swift`, `LocalGeneration.swift`, `MemoryPolicy.swift`, `CaptionLiveTranslation.swift`, existing lifecycle and benchmark tests.

- [ ] Profile capture start, preparation, ASR finalization, language analysis, cleanup, translation, queue wait and delivery separately. Record cold/warm p50/p95, load/retry counts and physical footprint; do not report one favorable average as the experience.
- [ ] Use measured bottlenecks to remove redundant language passes, unnecessary cleanup calls, duplicate preparation and avoidable model reloads. Preserve existing caches, ownership and native inference serialization.
- [ ] Measure cleanup-plus-translation reload cost before proposing concurrent model residency. Retain multiple large weights only if the 16 GB reference Mac shows no swap/pressure regression in the supported workload.
- [ ] Keep stable final translations ahead of interim previews and keep queue limits. Original captions continue under load; skipped/paused translation must remain visible and truthful. Do not improve measured speed by silently disabling requested processing.
- [ ] Verify power/thermal/memory-pressure handling and repeated short dictations; distinguish slower valid work from a stuck operation. Cancellation must drain safely and never paste a late result.

**Initial product goals to validate, not release limits or measured results:** warm 5–10-second dictation p95 ≤2.5 s with rules, ≤4 s with model cleanup, ≤5 s with cleanup plus translation; first meaningful Realtime caption ≤2.5 s from speech onset. Measure target-caption first/final delay separately before selecting its hard budget. Preserve existing release ceilings until reviewed measurements justify any policy change.

**Acceptance:** Before/after evidence names the model, language, hardware, settings and quality outcome. A faster result with more missing words, changed meaning or repeated fallback is a failed optimization.

## Milestone 6: Make the whole app easy to use and recover from

**Outcome:** One clear next action at setup and when something fails; useful text survives the entire user workflow.

**Files:** Existing settings/onboarding views, `AssetControl.swift`, bubbles, `TextInserter.swift`, `DictationState.swift`, `TranscriptStore.swift`, `TranscriptSummary.swift`, `Export.swift` and localization resources.

- [ ] Verify fresh installation and upgrade with the current simple settings. Keep everyday presets/cleanup/translation choices visible and fine settings collapsed. Improve capability/readiness copy without presenting every internal uncertainty as another toggle.
- [ ] Offer a compatible model/repair action when source/target support or installed assets are insufficient. Recommendations must reflect measured mode/language quality; do not silently download or replace a model during speech.
- [ ] Test actual microphone/system-audio permission denial/recovery, TextEdit and another ordinary app, focus changes, secure fields, clipboard-only delivery, Retry Copy and Copy Original. Real delivery tests are separate from fake inserter tests.
- [ ] Verify bubbles and transcript reading with CJK, Thai, Arabic/Hebrew RTL, mixed direction, combining marks, numbers, long words and fallback fonts. Check both screen display and actual copied/inserted/exported Unicode order. Keep native keyboard/VoiceOver access and Reduced Motion/Contrast/Transparency behavior.
- [ ] Verify full-session Save, translation association, cancellation, summary-only removal, retention failures and upgrade preservation with multilingual text. Reuse existing storage safety work; only patch newly observed defects.
- [ ] Make summaries explicit about output language. Single-language sessions preserve that language; ambiguous mixed sessions need an understandable language choice in the existing reader before generation. Do not add an automatic summary or another global setting. Check model token budgets with dense/non-Latin input and preserve whole-line omission disclosure.
- [ ] Keep SRT/WebVTT faithful to spoken lines and usable in actual players. Measure reading/wrapping behavior by script; do not assume Latin word/character rates transfer unchanged to every language.
- [ ] Keep diagnostics content-free by default: engine/mode, source/target identifiers, uncertainty/fallback reason, timings and load state. Debugging should identify the failed stage without logging recordings or conversation text.

**Acceptance:** A user can install, start, receive readable text, translate intentionally, recover originals and reopen saved material. Capability gaps and failures have useful actions; no false successful paste/translation/save state.

## Milestone 7: Build manageable multilingual quality evidence

**Outcome:** Repeatable, language-appropriate evidence that can grow beyond the developer's own languages.

**Files:** Existing benchmark fixture/scorer/harness files, `scripts/quality-matrix.sh`, `scripts/verify-quality.py`, `scripts/benchmark_evidence.py`, `docs/benchmarks/release-quality.json` and the release checklist.

### Coverage strategy

Run cheap deterministic capability/Unicode/contract tests across every offered entry and relevant script family. Natural-speech verification starts with 12 language/variant cohorts: English, German, Japanese, Simplified Chinese, Traditional Chinese, French, Spanish, Portuguese, Arabic, Russian, Hindi and Korean. This is the first validation cohort, not a hard limit on available languages.

Next add Turkish, Ukrainian, Persian, Urdu, Bengali, Tamil, Thai, Vietnamese and other declared model languages based on actual usage, reported failures and reviewer availability. Bengali/Tamil/Thai/RTL and related structural cases enter pure tests immediately; their natural-speech claims wait for reviewed evidence.

- [ ] Obtain authorized natural recordings, license/consent/provenance and independent source transcripts. Target 20 clips per initial cohort from at least three speakers: 12 ordinary clean cases, four difficult/noisy cases and four cases covering names/numbers/negation/repairs or continuous speech. Label conditions so good averages cannot hide an entire bad class.
- [ ] Include a small set of genuine within-utterance switches: German/English, Japanese/English, Chinese/Japanese and another shared-script pair. Include accents and speech without deliberate pauses; no synthetic-only quality certification.
- [ ] Run initial raw-ASR quality screening once across the larger corpus. For required release latency/evidence cases, retain at least five repetitions. Reuse the existing strict gate; screening results and skipped combinations are not release passes.
- [ ] Use a recorded representative engine/settings/target matrix rather than every language × every model × every target. Required cases cover each recommended mode, both caption tiers, actual model cleanup, translation engines, draft behavior and known risks. Record exactly which cells are verified, unsupported or untested.
- [ ] Validate one common cross-language target and each tested language's own target, plus specific variant conversions and reported problem pairs. Do not claim thousands of untested source/target pairs from a few good English/German examples.
- [ ] Use WER/CER with reviewed tokenization and normalization per writing system, not a universal whitespace/scalar interpretation. Test combining characters, morphology and no-space languages; measure omissions and language-switch errors separately from a sequence merely containing the expected labels.
- [ ] Review translation/cleanup for meaning, entities, numbers, negation, omissions and naturalness. Exact reference wording alone cannot decide whether a paraphrase is valid; allow independently reviewed reference alternatives while retaining hard factual/language checks. Keep existing gate limits until changes are justified by reviewed data.
- [ ] Bind measurements to exact clean source, model/corpus hashes, hardware/toolchain/settings and successful completion markers. Preserve actual model-call coverage and target-latency calibration requirements. Keep speech/reference content out of Git and public logs.

**Acceptance:** A quality report states what works for which mode/engine/language and what remains unverified. Missing native reviewers, corpus permissions, weights or hardware are named gates; none is silently treated as a pass.

## Milestone 8: Release the verified improvement cycle

- [ ] Finish focused regressions and independent code review, then the supported full release suite, normal hook-free build and signed native smoke. Preserve all existing assertions and unrelated tests.
- [ ] Finish the required real-model corpus cases, target-latency calibration and signed-app/upgrade/permission/device trials. Verify macOS 26 and 27, including the previously affected M4 Air; unavailable devices stay untested.
- [ ] Review the native product in shipped interface languages and check the public documentation through ego-browser. Update claims/defaults/recommendations to match current evidence.
- [ ] Produce a new local candidate and durable build-matched evidence for user testing. Existing `2.7.0-rc.1` does not contain the future language fixes.
- [ ] Publish a notarized release, assets and Sparkle/public-site changes only after applicable gates pass and a release request. Until then, use local candidates with explicit limitations.

Verification entry points remain:

```sh
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
./build-app.sh --no-test-hooks
scripts/verify-release.sh build/sAiity.app
build/sAiity.app/Contents/MacOS/sAiity --selftest 20
PYTHONDONTWRITEBYTECODE=1 python3 Tests/release_quality_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/benchmark_evidence_test.py
git diff --check
```

Real inference uses the existing authorized corpus/matrix paths, installed weights and a clean source revision. These commands are verification instructions, not work performed while writing this roadmap.

## Practical sequence and effort

| Cycle | Work | Dependency / completion checkpoint |
| --- | --- | --- |
| A — coverage and first failures | Milestone 1, start corpus/reviewer work; language/script/variant fixes in Milestone 2 | Capability mappings and demonstrated regressions pass; unresolved coverage remains explicit |
| B — faithful processing | Milestones 3–4 using baseline and first reviewed fixtures | Complete original recognition, safe cleanup and complete translation; meaningful false-positive/negative tests |
| C — speed and user workflows | Milestones 5–6 using stage timings and actual app trials | Quality-preserving before/after measurements, usable Unicode/RTL/recovery and truthful setup |
| D — qualification and release | Milestones 7–8, plus remaining model/device/corpus checks | Build-matched report, verified recommendations and a reviewable release candidate |

Planning estimate: roughly 10–20 engineering working days for the first bounded code/verification cycle, assuming dependencies and tools work. Corpus licensing, native-language review and unavailable hardware are separate work and can determine the actual finish date. This is not a calendar commitment or a promise to validate every catalog language in that period. Further languages join through the same evidence process after the core implementation; they do not require another language-specific architecture.

## What success looks like

Users lose fewer words and facts, intentional language switches survive, translation covers the requested message, common dictations return quickly, and setup/recovery are easy. Every offered language has truthful capability/state information; supported quality claims have real evidence. All-language handling is improved through the shared pipeline, while language-specific quality and defaults are expanded only as measurements justify them.
