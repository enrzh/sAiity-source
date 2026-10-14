# Japanese and mixed-language processing implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans to implement this plan task by task, with focused regression checks and an independent final review.

**Status:** Proposed for implementation. The user requested this plan; no application behavior is changed by writing it.

**Scope update:** The user subsequently requested a realistic whole-product/all-language plan. Use [the broader product roadmap](2026-10-09-product-quality-and-language-coverage.md) as the primary plan; retain this file as the detailed Japanese regression brief for its language-handling milestone.

**Goal:** Recognize and process Japanese as one language across kanji, hiragana and katakana, preserve real language switches, and prevent visibly incomplete translations from being reported as successful.

**Architecture:** Repair the existing language/span utilities and reuse their decisions in captions, dictation, cleanup and translation. Keep audio-region decoding, sequential inference, loaded models, original-text recovery and the current UI. Script identifies writing-system evidence; it must not automatically assign a spoken language.

**Tech stack:** Swift, Foundation/NaturalLanguage, existing Unicode/regex utilities, Swift Testing, installed local recognition and translation engines.

## Global constraints

- Work in `/Users/enrico/Documents/GitHub/saiity`, currently `codex/product-release-ready` at `44f8a6f` with extensive preserved uncommitted work. Recheck Git and active workers/builds before starting.
- Preserve all existing dirty/untracked changes and recovery state. This plan authorizes no commits, pushes, tags, GitHub release, Sparkle update or Pages deployment.
- Reuse existing files/types. Add small functions only where multiple real callers need the same policy; no new Manager, Service, Protocol, model dependency or settings screen.
- Keep everything local. Do not download weights, record new speech, change permissions or access private transcript contents without the corresponding authorization.
- If workers are used, route them to `sub2api/gpt-6.1-sol`. Main owns serial Swift builds/tests and native inference. Use ego-browser for website interaction.
- Do not alter recognizer configuration, deferred dictation segmentation, model residency, explicit Whisper language choices or the single-operation inference gates to fix text-language handling.
- Preserve actual spoken text, per-region language information, punctuation, spacing, names, numbers, negation and existing translation-off behavior. A dominant language is metadata, never an instruction to rewrite other spans.
- Keep cleanup and explicit translation separate. Model cleanup must preserve the original languages; enabled translation must cover the entire message in the requested target language.
- Use meaningful regression tests before each behavioral fix. Keep unrelated assertions and release-quality limits intact.

## Verified starting point

Read-only execution of the current utilities reproduced these results on macOS 27:

| Input | Current result | Required result |
| --- | --- | --- |
| `日本語の字幕を確認してください。` in caption span detection | Six alternating Chinese/Japanese spans; marked mixed | One coherent Japanese span |
| `明日の会議は東京で行います。` in caption span detection | Eight alternating Chinese/Japanese spans | One coherent Japanese span |
| Japanese text beginning with kanji, recognizer tag `zh` | Dictation keeps `zh` despite clear Japanese kana/grammar | Japanese source context; original text unchanged |
| Same Japanese sentence beginning with kana, tag `zh` | Dictation corrects to `ja` | Same decision regardless of first script |
| `字幕` without context | NaturalLanguage favors Chinese but with low confidence | Ambiguous; no forced Chinese assignment |
| English output containing `確認してください` | Whole-output classifier reports English at 0.998 | Clearly untranslated Japanese grammar cannot pass solely on dominant English |

The caption detector splits at every script transition before its Han-language check can see kana. Dictation joins Han/kana but retains the first script and can preserve an incompatible audio tag. The translation validator currently checks only the whole output's dominant language, with a 24-character minimum. Both MADLAD and Hy-MT2 infer source language themselves: source-tag correction alone will not restore the context lost by over-segmentation.

These are text-policy reproductions. They do not establish which recognizer/model produced the user's original output, or whether the actual ASR words were correct.

## Recommended approach and alternatives

Use one conservative policy for coherent spans, followed by target-aware output validation. This fixes the demonstrated routing/context defects without another model load or a language-switch button.

A Japanese-specific patch in captions alone would be smaller but leave dictation, target-language skipping and cleanup disagreeing. Replacing recognition/translation models immediately would require new quality evidence while leaving the demonstrated preprocessing defects in place. Reconsider model selection only after corrected routing has been measured on the same reviewed speech fixtures.

## Task 1: Preserve Japanese phrase boundaries in captions

**Modify:** `Sources/sAiity/CaptionProcessing.swift`, `Sources/sAiity/LanguageDetector.swift`.
**Test:** `Tests/sAiityTests/CaptionProcessingTests.swift`, `Tests/sAiityTests/LanguageTests.swift`.

**Existing interfaces:** `CaptionLanguageSpanDetector.analyze(_:fallbackLanguage:)`, `isMixed(_:)`, `LanguageDetector.languageCode(in:minimumCharacters:minimumProbability:)`, `LanguageRecognizerPool.classify(_:)` and `TranslationLanguage.baseCode(_:)`.

**Small shared addition:** Implement source resolution inside the existing `LanguageDetector`:

```swift
static func sourceLanguage(in text: String, hint: String? = nil) -> String?
```

The input is a coherent local span, not the entire accumulated session. `hint` is that span's recognizer language when available. Return a supported existing language identifier or nil for insufficient evidence; use the existing base-code comparison when comparing regional forms. Do not create a second stored language state.

- [ ] Add and observe this regression before changing detection:

```swift
@Test("Japanese kanji and kana form one language span",
      arguments: ["日本語の字幕を確認してください。", "明日の会議は東京で行います。",
                  "これは日本語の文章です。", "カタカナと漢字を確認します。"])
func japaneseScriptsStayTogether(_ text: String) {
    let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "zh")
    #expect(spans.map(\.text) == [text])
    #expect(spans.map(\.language) == ["ja"])
    #expect(!CaptionLanguageSpanDetector.isMixed(spans))
}
```

- [ ] Remove character-by-character Han/kana language splitting. Classify the intact Japanese phrase so its kana and grammar remain available to the resolver. Existing `RegexCache`/Unicode checks can identify kana, including half-width katakana, without normalizing the returned text.
- [ ] Make source resolution use meaningful whole-span evidence before an incompatible hint. Clear Japanese kana in a coherent Japanese span can correct `zh`; clear Chinese clause evidence can correct an incompatible Japanese hint. Retain compatible per-region identifiers and use existing confidence gates for probabilistic decisions.
- [ ] For Han-only fragments too short or uncertain to classify, use a compatible per-region hint when present; otherwise return nil. Do not label `字幕` or `東京` Chinese merely because their characters are Han.
- [ ] Preserve real Chinese/Japanese switches at sufficiently evidenced phrase/clause boundaries. Test `这是中文，请先检查发票。これは日本語の説明です。` with Chinese and Japanese parts kept separate and all source characters retained. Do not relabel an entire sentence Japanese merely because kana occurs somewhere in it.
- [ ] If an unpunctuated Chinese/Japanese boundary cannot be established confidently, preserve the coherent text and unknown source for automatic translation. Do not invent a precise boundary or drop either span.
- [ ] Keep existing German/English splitting and CJK joining regressions. Ensure repeated phrases such as `はい、はい。` are not deduplicated during language coalescing: use the existing disjoint concatenation path rather than overlap removal for these spans.
- [ ] Run focused tests, inspect changes, and review the shared resolver before connecting dictation.

## Task 2: Make dictation language metadata agree with actual text

**Modify:** `Sources/sAiity/DictationTranscription.swift`.
**Test:** `Tests/sAiityTests/DictationTranscriptionTests.swift`, `Tests/sAiityTests/DictationCleanupSessionTests.swift`.

**Consumes:** `LanguageDetector.sourceLanguage(in:hint:)` and corrected `CaptionLanguageSpanDetector` decisions from Task 1.
**Preserves:** `DictationRegionTranscript`, `DictationTranscriptionResult.regions`, `languageMetadata` and `translationRuns`; no new UI representation.

- [ ] Add and observe the mismatched-tag regression:

```swift
@Test("Japanese script order cannot preserve a conflicting Chinese tag",
      arguments: ["日本語の字幕を確認してください。", "これは日本語の文章です。"])
func japaneseTextCorrectsConflictingHint(_ text: String) {
    let result = DictationTranscriptionResult(text: text, language: "zh")
    #expect(result.text == text)
    #expect(result.regions.map(\.language) == ["ja"])
    #expect(!result.languageMetadata.containsMultipleLanguages)
}
```

- [ ] Route Han/kana resolution through the shared policy instead of the first character's script and unconditional `ja`/`zh` tag retention. Preserve the existing conservative rule for short Latin names/fillers and avoid unrelated changes to audio decoding.
- [ ] Test correct/mismatched/unknown tags, regional tags (`ja-JP`, `zh-Hans`, `zh-Hant`), kana-first/kanji-first forms and ambiguous Han-only fragments. Add a long unambiguously Chinese phrase with an incorrect Japanese hint; do not claim that every short Han-only phrase can be resolved from text.
- [ ] Test English–Japanese–English and Chinese–Japanese–Chinese. Preserve original order, complete text and per-span metadata; `translationRuns` may combine adjacent compatible spans, never erase a real language switch.
- [ ] Confirm ordinary Japanese is not described as mixed solely because kanji and kana coexist. Latin product identifiers inside Japanese must not trigger a cleanup instruction to translate or normalize the sentence.
- [ ] Derive confirmed language mixing from the corrected span evidence. A writing-system count alone must not declare a known single-language Japanese phrase multilingual; unresolved content still reaches conservative cleanup/automatic translation without a fabricated source tag.
- [ ] Run existing independent Whisper Auto and sequential Nemotron/reset/cancellation tests. Neither engine should decode an extra time to repair text metadata.

## Task 3: Preserve language through cleanup and target-language skipping

**Modify:** `Sources/sAiity/DictationCleanupValidator.swift`, `Sources/sAiity/TranslationEngine.swift`, `Sources/sAiity/AppDelegate.swift`; `Sources/sAiity/Translators.swift` only where prompt context needs correction.
**Test:** `Tests/sAiityTests/DictationCleanupValidatorTests.swift`, `Tests/sAiityTests/TranslationProcedureTests.swift`, `Tests/sAiityTests/SentenceAssemblyTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`.

**Consumes:** corrected coherent spans and dictation metadata from Tasks 1–2.
**Preserves:** existing deterministic filler cleanup, model-required decisions, source recovery, bounded caption queues and translation-off semantics.

- [ ] Add cleanup tests where Japanese contains kanji/kana plus `Swift`, `API` and numbers. Preserve Japanese grammar, identifiers and negation; model cleanup translating the sentence into English must be rejected. Correct metadata must select Japanese filler handling rather than Chinese filler handling.
- [ ] Use the corrected source resolver for cleanup's language-sensitive rules and validation. A stale recognizer hint must not select the wrong filler table; do not infer that every change in writing system proves a different language.
- [ ] Verify `TranslationProcedure.isAlreadyInTarget` with ordinary Japanese, actual Japanese/English and Chinese/Japanese speech, and uncertain Han-only text. Skip only when all meaningful unprotected content has sufficient target-language evidence. Uncertainty should reach automatic translation, rather than silently retaining foreign text.
- [ ] Ensure caption and dictation translation callers pass coherent spans and use `auto` for unresolved source. Avoid sending individual Japanese particles or kanji nouns as independent translations just because the Unicode script changed.
- [ ] Use the existing fake `TranslationProcedureTests.Engine` to assert the actual text and source passed into translation. Test Japanese → English, Japanese → German and mixed Japanese/English → English; when one necessary span fails, the whole original remains recoverable.
- [ ] Exercise the real AppDelegate sentence path with the existing held/fake translator: partial revisions, punctuation closure, display translation off/on and late completion must retain matching history rows. Keep live-caption lifecycle behavior and scroll stability intact.
- [ ] Run existing code-switching and cleanup regressions; unchanged output text is not sufficient unless its language metadata and downstream calls also match.

## Task 4: Reject clearly incomplete translations without banning valid scripts

**Modify:** `Sources/sAiity/TranslationOutputValidator.swift`, `Sources/sAiity/TranslationEngine.swift`; `Sources/sAiity/Translators.swift` and `Sources/sAiity/HyMT2Translator.swift` only for their existing validation/retry integration.
**Test:** `Tests/sAiityTests/TranslationOutputValidatorTests.swift`, `Tests/sAiityTests/TranslationProcedureTests.swift`, `Tests/sAiityTests/TranslationBatchTests.swift`, `Tests/sAiityTests/HyMT2TranslationTests.swift`.

**Existing contract:** `TranslationOutputValidator.sanitize(_:input:target:) -> Verdict`, `.rejected(why:retryable:)`, the strict batch marker parser and all-or-original behavior.

- [ ] Observe these targeted failures first:

```swift
@Test("dominant English cannot hide untranslated Japanese grammar")
func japaneseRemainderIsRejected() {
    let verdict = TranslationOutputValidator.sanitize(
        "Please 確認してください before continuing with the meeting.",
        input: "会議を続ける前に確認してください。", target: "en")
    guard case .rejected(_, let retryable) = verdict else {
        Issue.record("incomplete translation accepted")
        return
    }
    #expect(retryable)
}

@Test("Japanese output may legitimately contain kanji")
func japaneseKanjiOutputIsAccepted() {
    guard case .ok = TranslationOutputValidator.sanitize(
        "明日の会議は東京で行います。",
        input: "Tomorrow's meeting will be in Tokyo.", target: "ja") else {
        Issue.record("valid Japanese rejected")
        return
    }
}
```

- [ ] Add target-aware checks for meaningful residual foreign spans before accepting output solely on dominant language. A clearly untranslated Japanese grammatical phrase in an English/German result is retryable even if the whole sentence is confidently classified as English/German or shorter than 24 characters.
- [ ] Preserve protected vocabulary, names, URLs, email addresses, numeric content, acronyms and technical identifiers. Do not reject every Han character in English output or require kana in every valid Japanese output. Add explicit positive cases for a protected Japanese name, `Swift`, `API`, Han-only Japanese output and legitimate Chinese output.
- [ ] Treat uncertain Han-only remnants conservatively. Use source context, existing protected-term/name evidence and confident language evidence; a short ambiguous proper name does not prove failed translation. Report this limitation rather than creating an unreviewed vocabulary blacklist.
- [ ] Apply the verdict to both batch slices and final combined output so one mostly correct slice cannot hide another untranslated slice. Malformed or missing markers remain failures; preserve the existing sequential fallback when batching fails.
- [ ] Reuse Hy-MT2/local-LLM's existing one-retry behavior. For MADLAD, if a clearly incomplete result needs a retry, permit at most one additional sequential decode of the same coherent input. Do not reload models or add another inference pipeline. After the allowed retry fails, preserve the original and existing recovery feedback.
- [ ] Keep rejection reasons content-free: codes such as `untranslated span`, target language and timings, never quoted user speech. Do not add model instructions or transcript snippets to public diagnostics.
- [ ] Run focused positive and negative tests, including existing name/number/echo protections. A stricter validator that rejects valid Japanese or Chinese is a regression.

## Task 5: Measure routing cost and verify actual speech/model behavior

**Use/modify as needed:** `Tests/sAiityTests/DictationASRPerformanceTests.swift`, `Tests/sAiityTests/CaptionASRPerformanceTests.swift`, `Tests/sAiityTests/HyMT2TranslationTests.swift`, `docs/benchmarks/README.md`, `docs/release-checklist.md`.

- [ ] Measure the existing and corrected pure span/validation utilities on the same bounded text cases. Record repeated warm p50/p95 runtime, resulting span count and translator-call count. Favor coherent language spans rather than increasing inference work to fix a character-classification bug.
- [ ] Through fake engines, prove ordinary Japanese is sent as one meaningful translation unit and correction does not add an ASR pass, model reload or parallel inference. Record retries separately; rejected output must not become a fast-but-incorrect success.
- [ ] Using authorized reviewed recordings and already installed weights, separately verify audio language tags, raw recognized words, resolved spans, cleanup result, translated result and original recovery. A text-only fixture cannot prove that the ASR heard Japanese correctly.
- [ ] If raw recognition itself substitutes Chinese words for spoken Japanese, classify that as an ASR-quality failure and preserve the evidence. Text cleanup must not reconstruct guessed Japanese and claim that recognition was repaired; compare installed recognizers on the same approved recording before proposing an engine change.
- [ ] Run the following reviewed matrix; keep source/target reference text and recordings outside Git and logs:

| Speech/input | Processing modes | Required observation |
| --- | --- | --- |
| Ordinary Japanese, kanji-first and kana-first | Captions 1120/2240; Nemotron/Whisper Auto dictation | Correct complete Japanese text; coherent Japanese metadata |
| Japanese containing katakana, `Swift`, `API`, names, numbers and negation | Cleanup off/rules/model | Intended words and language survive; original recoverable |
| Short ambiguous Han-only phrases | With/without per-region language evidence | No unjustified Chinese assignment or silent translation skip |
| Japanese → English and Japanese → German | Installed MADLAD and Hy-MT2 | Entire message translated; no unexplained Japanese grammatical remnants |
| English–Japanese–English | Translation off/on | Languages preserved when off; all spans reach the target when on |
| Chinese–Japanese–Chinese, including natural switches without a deliberate pause | Translation off/on | Chinese is not globally relabelled Japanese; uncertainty is not hidden |
| Pure simplified/traditional Chinese and Korean | Translation off/on | Shared Han characters do not break other supported languages |
| Ordinary German/English and their existing mixed fixtures | Existing processing modes | No new omissions, changed metadata or latency regression |

- [ ] Record first original/translated caption latency, release-to-result, retry count, omissions/errors, language-span correctness, load count and peak memory. Keep cold/warm and caption/dictation measurements separate.
- [ ] If corpus, engine weights or hardware are unavailable, mark that case not tested and retain the release gate. Do not synthesize a passing natural-speech corpus or loosen limits. Revisit model recommendations only with measured, reviewed before/after evidence.

## Task 6: Final verification and candidate handoff

- [ ] Recheck no overlapping Swift/native worker is active. Use existing temporary transcript libraries and in-memory fake engines; preserve real preferences/data and all previous implementation changes.
- [ ] Run the focused regression command after each connected task:

```sh
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter 'CaptionProcessingTests|LanguageTests|LanguageRecognizerPoolTests|DictationTranscriptionTests|DictationCleanupValidatorTests|DictationCleanupSessionTests|TranslationProcedureTests|TranslationOutputValidatorTests|TranslationBatchTests|HyMT2TranslationTests|CaptionAssemblyIntegrationTests'
```

Expected: observed new regressions fail before their respective fixes, then pass alongside all existing cases. Opt-in model probes remain disabled unless their authorized inputs are available.

- [ ] Run the full supported release suite, normal hook-free build, native smoke and existing quality-script checks:

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

- [ ] Obtain independent review of the shared-policy callers and target-output false positives/negatives. Review confidence/ambiguity handling, cleanup preservation, batch/retry cancellation and unchanged caption resource ownership.
- [ ] Update documentation with concrete behavior, measurements and known limitations. Bind evidence to the actual source/build and save a new local testing candidate after successful checks; the existing `2.7.0-rc.1` candidate predates these changes.
- [ ] Preserve the existing public-release gates and require a release request before notarization/publication/tag/appcast/Pages actions. A passing mocked suite is not a claim that all Japanese/Chinese speech is recognized correctly.

## Completion criteria

Ordinary Japanese no longer becomes alternating Chinese/Japanese spans; mismatched audio tags cannot defeat clear Japanese text evidence; ambiguous shared characters remain honestly uncertain; real language switches and original words survive cleanup; enabled translation covers every meaningful span or preserves the original with honest failure handling. Pure tests, caller integration, actual model/speech quality and measured performance must each have their own evidence before their respective gates are marked complete.
