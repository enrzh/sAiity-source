# Local Dictation Cleanup, Whisper Models, and Native UI Design

## Status and Baseline

This is an implementation-ready design specification for macOS only. The
baseline is `main` at `c227ca0`, with a clean working tree and two documentation
commits ahead of `origin/main`. No tests are claimed to have passed by this
document. The implementation plan must turn the contracts below into RED and
GREEN tests before changing production code.

The design follows general macOS principles: clear state, predictable focus and
keyboard behavior, native controls, sufficient contrast, reduced motion, and
VoiceOver-readable labels. The repository has no available `apple-design`
references or HIG directory, so this document does not invent line-by-line HIG
citations.

## Goal

After push-to-talk release, sAiity may perform a strictly local, opt-in cleanup
of the authoritative dictation transcript, optionally translate that result,
and then copy or insert exactly one final string. Dictation may use a selectable
Whisper model for release-time batch inference while live captions continue to
use their existing streaming Nemotron/Parakeet path. The settings and toast
surfaces must make readiness, progress, failures, and accessibility behavior
understandable without redesigning the whole application.

## Scope

In scope:

- macOS push-to-talk dictation cleanup, its prompt contract, fallback, and
  ordering;
- post-release batch Whisper selection, download/readiness/loading state, and
  the 20-second recording limit;
- independent captions versus dictation model settings;
- `DictationToastWindow` presentation and frame persistence;
- the focused native toolbar/background and dictation permission recovery UI;
- focused unit and integration tests listed in the test matrix.

Out of scope:

- iOS, Windows, or Linux;
- always-on microphone capture, external transcription APIs, or transcript
  uploads;
- changing live caption recognition, caption translation, or caption rolling
  commit behavior;
- copying Tauri/Rust managers, `cpal`, or the Dictus architecture;
- a new app-wide visual rewrite, a merged overlay window, or speculative
  abstraction layers;
- release, signing, distribution, or performance claims.

## Existing Boundaries and YAGNI Rules

Reuse the existing `ASRBackendPool`, `IdleEviction`, `ModelRegistry`,
`DictationController`, `AVAudioEngine` capture, `DictationToastWindow`,
`OverlayWindow`, and `FrameStore` patterns. Keep behavior in existing types and
functions. Do not add a Manager, Service, Factory, Strategy, Protocol, Adapter,
Coordinator, Provider, or Registry unless an existing boundary demonstrably
requires it; the default implementation is a small change to current types.

The Dictus `d49d270` implementation is reference material only. Borrow these
behavioral ideas: preparation separate from recording, serialized shortcut
lifecycle with a generation guard, draining on stop, releasing failed model
instances, and separate cleanup system/user prompts. Do not copy its Tauri or
Rust managers, `cpal`, external APIs, or always-on microphone behavior.

## Dictation Pipeline

The only accepted ordering is:

```text
authoritative transcript
  -> optional local cleanup
  -> optional dictation translation
  -> clipboard and/or text insertion
```

The authoritative transcript is obtained after recording stops and all pending
audio has drained. Partial callbacks and rolling caption finals are never sent
to cleanup, translation, clipboard, or insertion. Cleanup is default off and
strictly local. When cleanup is enabled, it uses the existing local GGUF
generation runtime and the existing runtime lifecycle; it does not introduce a
second generation subsystem.

Cleanup has separate system and user prompts. The system prompt must constrain
the operation to correcting punctuation, casing, fillers, false starts, and
repetition while preserving meaning, names, numbers, ordering, and uncertainty.
It must explicitly prohibit summary, translation, expansion, explanation,
invention, and adding information. The user prompt contains only the
authoritative transcript. The output is accepted only when non-empty and
otherwise treated as failure. On nil, error, cancellation, or empty cleanup
output, use the original authoritative transcript. Cleanup errors must never
prevent insertion of usable original speech.

Translation, when enabled, receives the selected whole dictation result after
cleanup. Translation is independent of cleanup and is never used to repair a
cleanup failure. A stale or cancelled generation must discard all later
translation and insertion work. Successful completion performs one clipboard
write and/or one insertion operation, never one operation per intermediate
stage.

## Whisper Model Contract

Whisper is used only for push-to-talk dictation batch inference after release.
It is never the caption engine and never processes live partials. Captions
continue to use the currently selected streaming Nemotron or Parakeet model.
Changing a dictation Whisper selection cannot change caption selection, model
readiness, running state, or translation settings, and changing caption
selection cannot change dictation readiness.

The first release has exactly these two selectable model IDs:

1. `whisper.base.en.gguf`: OpenAI Whisper `base.en`, GGUF, English-only,
   balanced latency and accuracy.
2. `whisper.small.en.gguf`: OpenAI Whisper `small.en`, GGUF, English-only,
   higher accuracy and latency.

The catalogue must store the exact source URL, license text, expected byte
size when published, and SHA-256 checksum for each asset. An implementation
may expose a model as downloadable only after those values and the complete
GGUF asset have been verified in the release asset manifest. A missing URL,
checksum, license, or complete asset is a blocking model-catalogue failure,
not a silent fallback or a future decision. The implementation must not add a
third model in this scope.

Each Whisper model has independently visible states: `Not downloaded`,
`Downloading` with determinate or indeterminate progress, `Downloaded`/
`Ready`, `Loading`, `Ready for next dictation`, `Failed` with recovery action,
and `Partially downloaded` with retry or remove action. A selected but not
ready model provides an actionable Download/Retry control and cannot start
recording as if it were ready. Loading occurs after release or explicit
preparation and is represented in the toast/settings state. Failed instances
are released and do not remain in the pool. Reuse `ASRBackendPool` and
`IdleEviction` so loaded resources can be reused and evicted by existing
lifecycle rules.

Dictation recording is capped at 20 seconds. At the cap, capture stops through
the normal serialized release/drain path, the user sees a concise limit state,
and the available authoritative transcript still follows the normal fallback
and single-insertion rules. The cap is not applied to captions.

## Lifecycle and Concurrency

Preparation and microphone recording remain separate. Shortcut press starts at
most one preparation/start task; release stops capture promptly, marks the
session as transcribing, drains pending audio, and awaits the authoritative
batch result exactly once. A monotonically increasing generation token guards
preparation, startup, release, cleanup, translation, and insertion. Press,
release, cancel, permission changes, and a new session are serialized on the
existing controller actor/main-actor boundary.

Cancellation increments the generation, stops capture, awaits relevant tasks,
and releases or invalidates the failed/stale backend. A late completion may
update no phase, clipboard, or insertion. Phase changes are emitted only when
the phase actually changes; updating text or progress in the same toast does
not reset its phase or restart its display timer.

## Dictation Toast and Placement

Keep `DictationToastWindow` as a separate window. Do not merge it with the
caption overlay. Its visual language should match the subtitle bubble through
readable type, restrained opacity, border and shadow treatment, spacing, and
state hierarchy, while remaining a native macOS toast rather than a generic
floating card. Use a single readable native toolbar/background in the related
settings surface and correct excessive transparency.

The toast supports the lifecycle states needed by users: permission required,
preparing/loading, ready, recording, transcribing, cleaning, translating,
inserting, success, 20-second limit, and failure with a recovery action where
one exists. Model download/readiness controls are actionable from settings;
the toast reports their current state without becoming a model-management
window.

Dragging is a native whole-window drag. Toast frame persistence is independent
from caption frame persistence and uses its own stored key. A phase update must
not reset a user-dragged frame. Initial placement uses the active interaction
screen; after a successful drag, the saved screen and frame have priority.
When a display is removed or its resolution changes, placement must choose the
first valid fallback in this order: keep the frame if it does not overlap the
new visible area incorrectly, center on the selected fallback display, then
clamp within the visible frame. Negative screen coordinates are valid. No
saved frame may leave the toast unreachable.

Honor Reduce Motion and Reduce Transparency, Increase Contrast, and VoiceOver.
Reduced motion removes nonessential animation and uses immediate phase changes;
reduced transparency uses an opaque readable surface; increased contrast
strengthens boundaries and text contrast. Every state and action has a stable
VoiceOver label/value, and permission/model failures expose their recovery
action in the accessibility tree.

## Permissions and Settings UI

The dictation permission state is explicit: unknown/requesting, granted,
denied, and restricted/unavailable. Denied and unavailable states explain the
next supported recovery action, including opening the relevant macOS setting
when appropriate, and provide a retry/recheck action. Permission recovery must
not silently restart recording or alter caption permission state.

The settings changes are scoped to the existing screens: one native readable
toolbar/background, a dictation cleanup toggle defaulting off, independent
dictation Whisper selection/readiness controls, independent caption model
readiness controls, and the permission recovery row. Do not replace the whole
settings navigation or introduce a new settings architecture.

## Test Matrix

Tests are planned in TDD order: write each RED test first, then implement the
smallest change to make it GREEN. This document records no passing result.

| Area | Required assertions |
| --- | --- |
| Authoritative revision | An early rolling final is not inserted when release returns a revised authoritative transcript; the authoritative revision wins. |
| Cleanup fallback/order | Cleanup receives only the authoritative result; disabled cleanup is bypassed; nil, error, empty, or cancelled cleanup returns original text; translation follows cleanup and insertion occurs once. |
| Cleanup prompt safety | System and user prompts are separate and require punctuation/casing/filler/false-start/repetition correction while prohibiting summary, translation, expansion, and invention. |
| Captions independence | Caption Nemotron/Parakeet selection and streaming callbacks remain independent from dictation Whisper selection, readiness, and batch loading. |
| Whisper assets/readiness | Both fixed model IDs have complete manifest metadata; partial/download/loading/ready/failed states expose the specified actions and failed instances are released. |
| 20-second limit | Capture stops at 20 seconds, follows drain/release ordering, reports the limit, and does not change caption duration behavior. |
| Shortcut races | Repeated press/release/cancel and permission changes are serialized; generation guards prevent stale phase, cleanup, translation, clipboard, or insertion effects. |
| Audio drain | Stop waits for the audio queue/pump to drain and calls authoritative finalization once; cleanup never sees a partial. |
| Single insertion | A successful dictation produces one final clipboard/insertion operation, including cleanup and translation paths. |
| Toast placement | Independent frame persistence survives phases; initial active interaction screen, saved screen priority after drag, negative coordinates, removed displays, resolution changes, overlap, centering, and clamping are covered. |
| Toast phase | Progress/text updates do not reset phase, frame, or the phase display lifecycle. |
| Accessibility settings | Reduce Motion, Reduce Transparency, Increase Contrast, and VoiceOver labels/actions produce readable, stable states. |

## Implementation Plan Shape

One implementation plan can be formed from these bounded work units:

1. Extend the existing dictation completion boundary and controller lifecycle
   with authoritative release, drain, generation guards, 20-second cap, and
   focused RED/GREEN tests.
2. Add local cleanup invocation using the existing GGUF runtime, separate
   prompts, strict output validation, fallback, ordering, and tests.
3. Add the two fixed Whisper assets to `ModelRegistry`, readiness/download/
   loading/failure presentation, independent settings state, and model tests.
4. Refine the existing toast/settings surfaces for native background, states,
   permission recovery, independent frame persistence, placement recovery, and
   accessibility tests.
5. Run focused tests and `git diff --check`; report test evidence separately
   from release or distribution evidence.

## Acceptance Criteria

- macOS only, local-only cleanup, cleanup off by default, and no partial
  processing.
- Authoritative transcript, optional cleanup, optional dictation translation,
  and one final clipboard/insertion operation occur in that order.
- Cleanup failures and empty output preserve usable original speech.
- Exactly `whisper.base.en.gguf` and `whisper.small.en.gguf` are selectable,
  with verified complete assets and no unresolved model choice.
- Captions remain streaming Nemotron/Parakeet and settings remain independent.
- Recording stops at 20 seconds and all shortcut/audio races are generation-safe.
- Toast remains separate, draggable, persistently placed, phase-stable, and
  accessible across display and macOS accessibility changes.
- The change is limited to the existing boundaries and does not add
  speculative managers or rewrite the application UI.
