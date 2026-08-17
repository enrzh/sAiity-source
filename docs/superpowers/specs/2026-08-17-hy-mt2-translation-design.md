# Hy-MT2 Translation Specialist Design

## Goal

Add Tencent Hy-MT2-1.8B Q4_K_M as an opt-in, translation-specialized engine for sAiity while keeping MADLAD as the recommended default and leaving the existing Qwen/Gemma local-LLM path intact.

## Current Context

- `TranslationEngine` currently exposes MADLAD and a generic Qwen/Gemma GGUF path.
- MADLAD is the measured fast path and covers roughly 450 languages.
- The generic LLM path uses LLM.swift's built-in family templates and a Qwen-oriented prompt plus output sanitizer.
- The current LLM.swift binary contains Hunyuan dense model symbols, but its Swift template resolver does not identify `hunyuan-dense` and falls back to ChatML.
- Tencent's Q4_K_M file is 1,133,080,448 bytes and the model card documents Apache-2.0 licensing, 37 language codes/variants, and a custom llama.cpp/STQ dependency for its GGUF releases.

## Decision

Hy-MT2 will be a distinct `TranslationEngine` case, not another row in `LocalModel`. It gets one fixed registry asset, one fixed Q4_K_M download, its own model directory, its own 37-code provider, and an explicit Hunyuan chat template using the model's `<｜hy_User｜>`, `<｜hy_Assistant｜>`, and `<｜hy_EOT｜>` tokens.

MADLAD remains `TranslationEngine.recommended`. Selecting Hy-MT2 is explicit and reversible. The 1.25-bit and 2-bit variants are excluded until the bundled runtime includes and passes the required quantization-kernel test.

## Runtime Behavior

1. The Models page lists Hy-MT2 under Translation with its exact advertised size and Apache-2.0 license.
2. Captions → Translation presents Hy-MT2 as a third engine option. The existing default remains MADLAD.
3. Hy-MT2 downloads through the existing `DownloadCoordinator` and `FileDownloader`, validates the GGUF magic, and never shares a staging path with another asset.
4. Hy-MT2 uses a translation-only prompt in its user turn because the model card states that it has no default system prompt. The output is validated for non-empty text, non-echoed input, reasonable length, and target-language consistency where NaturalLanguage can identify the language.
5. A failed or incompatible load reports the normal translation-unavailable status and does not silently replace MADLAD or the source caption.

## Architecture

- `HyMT2Translator.swift` owns model location, download/load lifecycle, the explicit template, model-specific generation settings, and translation calls.
- `TranslationOutputValidator.swift` becomes the single shared output-validation implementation used by Qwen and Hy-MT2. This prevents two engines from silently accepting different classes of hallucinated output.
- `EngineLanguages.swift` adds a fixed Hy-MT2 language set and full-name prompt mapping.
- `TranslationEngine.swift` and `DownloadCoordinator.swift` provide the single source of truth for selection and asset identity.
- Settings copy explains that Hy-MT2 is specialized for the 37 language codes/variants listed by the model card and is not the broad-coverage choice; no default recommendation is changed.

## Compatibility Boundary

The Q4 model must be tested against the actual bundled llama framework before being called supported. The 1.25-bit and 2-bit files are not added to the catalogue. The implementation must not claim a successful model load or a latency number without a real model run.

## Test Requirements

- Hy-MT2 language aliases resolve regional BCP-47 codes to the model's base language names.
- The 37-code set is exact and does not advertise unsupported long-tail MADLAD languages.
- The registry contains one unique Hy-MT2 asset with the exact file size, safe path, install path, and delete path.
- The explicit Hunyuan template produces a BOS → user → EOT → assistant prompt and stops at EOT.
- Output validation rejects empty output, copied source, and wrong-language output while accepting a valid translation.
- Existing Qwen/Gemma and MADLAD tests remain green.

## Out of Scope

- Changing the default engine.
- Adding Hy-MT2 1.25-bit, 2-bit, Q6, or Q8 downloads.
- Shipping model weights inside the app.
- Claiming Hy-MT2 is faster or higher quality than MADLAD before the local benchmark.
- Changing the unrelated dirty dictation work already present in the checkout.
