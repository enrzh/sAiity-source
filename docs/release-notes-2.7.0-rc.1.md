# sAiity 2.7.0-rc.1 — local release candidate

This candidate improves reliability and makes everyday setup more direct. It is
prepared locally from `codex/product-release-ready`, based on `44f8a6f`, with the
implementation still uncommitted. It has not been published or offered by Sparkle.

- Captions stay busy until stopping finishes, protecting Start, saved-session
  processing and model removal during teardown.
- Saved-session retranslation publishes only if its captured spoken bytes are
  unchanged. Cancellation drains its owned work; late spoken lines and translation
  patches survive. Retention uses its captured library and reports actual deletion
  failures.
- Final translations update all retained caption rows. Original captions continue
  when the bounded translation queue is full, with a notice that some lines
  remain untranslated.
- Bubble Save confirms beside the action and opens the matching saved transcript.
  Saving uses all committed session lines, including those beyond the latest 50
  displayed rows.
- Dictation keeps a direct cleanup chooser and Download & Use. Failed, cancelled or
  stale downloads do not enable cleanup. Readiness includes the effective model,
  microphone and shortcut permissions.
- Processing and appearance presets remain visible; alternative engines and fine
  controls share one collapsed More options section. Preview cards show caption
  text, translations and dictation waveform/result proportions.
- Clipboard-only delivery is described honestly. Unavailable or rejected model
  cleanup retains the safe deterministic result and records the fallback.
- Speaker labels reject invalid, duplicate or incomplete audio evidence.
- German, French, Spanish and Japanese include the new controls and a localized
  microphone purpose. Disclosure motion respects Reduce Motion.

The expanded local quality matrix includes 1120/2240 ms timing, model cleanup and
Hy-MT2/MADLAD translation. It scores recognition and translation independently,
requires actual successful model-cleanup coverage and a verified run-completion
fingerprint, and retains first/final target-caption latency.

Fresh deterministic verification: the supported release command passed 669
registered tests across 81 suites in 13.809 s; 20 explicit model/device opt-ins
were skipped. Python quality/evidence checks passed 15 and 6 tests respectively.
These results do not establish natural-speech accuracy or faster native inference.

Release gates still outstanding: authorized reviewed speech corpus and target
translation references, measured cold/warm processing and memory, calibrated
translated-caption latency limits, macOS 26/27 device/permission/insertion/upgrade
trials, composited visual/accessibility verification and public-site review through
ego-browser. The production translation latency gate remains explicitly unverified
and refuses a complete quality pass. See [the checklist](release-checklist.md).

Local candidate artifacts are for testing. Notarization, release publication and
Sparkle updates follow completed verification and a release request.
