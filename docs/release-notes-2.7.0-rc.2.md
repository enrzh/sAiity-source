# sAiity 2.7.0-rc.2 — local language and processing candidate

This signed local candidate is based on the preserved `codex/product-release-ready`
checkout at `44f8a6f`, with uncommitted PRR/PQL changes. It is not notarized or
published, and it has not passed the real speech/device release gates.

- Whisper source choices follow the pinned recognizer vocabulary, including its
  native aliases. Automatic recognition and exposed audio-language tags are
  separate capabilities; Nemotron/Qwen do not claim universal source coverage.
- Japanese kanji/kana and Korean/Han stay in coherent phrases. Clear switches
  remain separate; short shared-script fragments stay uncertain. Language
  analysis preserves original Unicode, separators and paragraph boundaries.
- Cleanup preserves unhandled languages and meaningful repetitions. Numeric
  values, repeated facts, ISO dates, currency markers and negation have stronger
  guards; mixed cleanup can no longer pass by retaining one word from a span.
- Translation validates batch slices and the assembled message. Accepted slices
  are retained, rejected ones use the sequential path, and MADLAD has at most one
  additional decode. Cancellation is checked before native batch admission.
  Explicit Chinese script requests use local ICU conversion.
- Mixed saved transcripts offer a summary-language choice in the existing reader.
  Single-language sessions keep their language. The choice reaches map/reduce
  prompts and optional summary metadata; Markdown identifies it, while SRT/VTT
  remain spoken words. Existing summary JSON stays readable.
- A bounded cache removes repeated text-language analysis. Capability descriptions
  and new reader controls are localized in German, French, Spanish and Japanese.
- Quality evidence now requires reviewed language-specific scoring, complete
  reference alternatives, exact language sequences and output-bound semantic
  review. Twelve natural-speech cohorts remain explicitly unverified.

Local verification on Apple M4 / 16 GB / macOS 27.0.1 (26A434): 728 registered
Swift tests across 81 suites passed, with 20 explicit model/device probes skipped;
30 Python checks and 32 signed native smoke checks passed. German transcript
reader content was inspected at compact/default/large sizes, with native sheet
resize checks. These are implementation/layout evidence, not speech-quality,
actual insertion, full accessibility or end-to-end latency acceptance.

The styled Downloads DMG is `sAiity-2.7.0-rc.2-local.dmg`. Its SHA-256 is
`9b6c8d1757efeb2c514eca1e25fb8ad719ab301c8f5baeb667737e6462e1eb4b`.
Evidence is retained in `build/product-language-20261010/`. The previous local
candidate and unrelated working-tree/recovery state are preserved.

Text guards can decline valid short phrases, names or unfamiliar monetary
spellings; they cannot certify meaning. Raw ASR errors cannot be reconstructed by
cleanup. Natural recordings/references, independent review, cold/warm model and
memory measurements, target-caption calibration, macOS 26/device/permission/
insertion/upgrade trials and full accessibility remain required before release.
See [the release checklist](release-checklist.md).
