# Local Dictation Cleanup, Whisper Batch Inference, and Native UI Design

## Status and Baseline

This is an implementation-ready macOS-only specification. The historical
implementation baseline is `main` at `c227ca0`; the current specification
revision is carried by the commits after it, including `229ab995`. This
document makes no test or release claim. Implementation starts with focused
RED tests, followed by the smallest GREEN changes in existing types.

## Goal and Scope

After push-to-talk release, sAiity performs an opt-in, local cleanup of the
authoritative dictation transcript, optionally translates that result, and
performs one final clipboard and/or text insertion operation. Release-time
batch Whisper inference is selectable for dictation. Live captions retain
their streaming Nemotron/Parakeet path.

The scope covers macOS dictation cleanup, its prompts and fallback, batch
Whisper readiness and the 20-second recording limit, independent caption and
dictation settings, `DictationToastWindow` placement/accessibility, permission
recovery, and focused tests. It excludes iOS, Windows, Linux, external APIs,
uploads, live-caption changes, release/signing/distribution, app-wide
navigation redesign, merged overlay windows, and new abstraction layers.

## Existing Boundaries

Reuse `ASRBackendPool`, `IdleEviction`, `ModelRegistry`,
`DictationController`, `AVAudioEngine` capture, `DictationToastWindow`,
`OverlayWindow`, and `FrameStore`. Do not add a Manager, Service, Factory,
Strategy, Protocol, Adapter, Coordinator, Provider, or Registry. Keep the
behavior in the existing controller, pool, state, settings, and window types.

`DictationController.finishDictation()` already exists as the completion
boundary in the current implementation. The implementation must preserve that
boundary and its single authoritative-finalization call; it must not introduce
a second completion API.

## Dictation Pipeline and Cleanup Contract

The only accepted order is:

```text
authoritative transcript -> optional cleanup -> optional dictation translation
-> one clipboard and/or text insertion operation
```

Recording release stops capture, drains pending audio, and obtains the
authoritative batch result. Streaming partials, rolling caption finals, and
intermediate hypotheses never enter cleanup, translation, clipboard, or
insertion. Nemotron/Parakeet dictation and captions continue to share the
existing `ASRBackendPool`; Whisper is a dictation-only batch holder after
release and never replaces captions. If captions are active, dictation is
rejected by the existing exclusive-use rule and does not run in parallel.

Cleanup defaults off and uses the existing local GGUF generation runtime.
The system prompt requires only punctuation, casing, filler, false-start, and
repetition correction. It preserves meaning, names, numbers, ordering, and
uncertainty, and explicitly forbids summary, translation, expansion,
explanation, invention, and added information. The user prompt contains only
the authoritative transcript; system and user prompt boundaries remain
separate. Output is trimmed, then validated: it must be non-empty, contain no
Markdown fence marker or fenced block, and contain no prose surrounding the
cleaned transcript. Invalid fenced output is a cleanup failure.

For cleanup error, timeout, nil output, trimmed-empty output, or invalid
fenced/prose output, select the original authoritative transcript and continue
to translation and insertion. Cleanup failure never discards usable speech.
Translation receives the selected whole result after cleanup. Translation
failure likewise selects the original dictation result. A user cancel or new
generation discards every pending and completed downstream output and performs
no clipboard write or insertion.

## Whisper Selection and Asset Ownership

The first release selects exactly these two official Whisper model IDs:

1. `openai_whisper-base.en` (Whisper `base.en`), English-only, lower latency.
2. `openai_whisper-small.en` (Whisper `small.en`), English-only, higher
   accuracy and latency.

The current `Package.swift` and `Package.resolved` contain no WhisperKit
dependency. Adding a dependency is a separate implementation change outside
this documentation commit. The executable implementation must use an approved
WhisperKit version and its documented model IDs/download API before coding
against it; the two IDs above are the complete first-release selection.

WhisperKit owns model download, staging, integrity verification, local cache,
partial-transfer recovery, and removal. The spec does not invent source URLs,
SHA values, byte sizes, license fields, or a `ModelAsset` manifest. Whisper
models are not registered with `ModelRegistry`. Readiness comes from the real
WhisperKit local-model state for the selected ID, never from a fabricated
registry entry or a file-presence guess. `ModelRegistryTests` therefore retain
their no-Whisper assertions and continue to cover only registry-owned assets.

Settings exposes exactly the two IDs with independent states: Not downloaded,
Downloading (determinate or indeterminate), Downloaded/Ready, Loading, Ready
for next dictation, Failed with Retry, and Partially downloaded with Retry or
Remove. Download, Retry, and Remove are actionable. A selected model that is
not ready cannot start recording as ready. WhisperKit owns its batch holder
and cache lifecycle; the existing `ASRBackendPool` remains the shared
streaming Nemotron/Parakeet pool. Failed holders are released. Whisper batch
inference is dictation-only and does not alter caption selection, caption
readiness, caption running state, or translation settings.

## Lifecycle, Audio Cap, and Races

Preparation and microphone recording remain separate. The existing controller
serializes shortcut press, release, cancel, permission changes, and new
sessions on its current main-actor boundary. Release marks `transcribing`,
drains pending audio, and finalizes exactly once through the existing
`finishDictation()` boundary.

The 20-second cap is based on successful conversion to 16 kHz mono: exactly
320000 accepted mono samples reaches the cap. Capture then stops through the
normal release/drain path and enters `transcribing`; the cap does not affect
captions. Samples that fail conversion do not advance the count.

Cap, release, cancel, and late task completion use one terminal-transition
function guarded by the session generation. The first accepted terminal event
wins. A cap event enters transcription; cancellation wins only if its terminal
transition is accepted first. A cancel or new generation invalidates all later
cleanup, translation, clipboard, insertion, and phase updates and releases or
invalidates stale holders.

## Toast, Placement, and Accessibility

`DictationToastWindow` remains separate from the caption overlay. Preserve the
existing subtitle-bubble visual language with readable type, restrained
opacity, border, shadow, and spacing. Do not add gradients or fading
backgrounds. Toast phases are permission required, preparing/loading, ready,
recording, transcribing, cleaning, translating, inserting, success, 20-second
limit, and failure with its recovery action.

Phase changes do not relocate the window, reset a dragged frame, or restart a
phase timer. Progress/text updates do none of those actions. Persist the toast
frame as an `NSRect` string under a key distinct from the caption frame key.
Placement selection is: saved frame with center containment first, then the
display with greatest visible-frame overlap, then a valid fallback. Clamp the
whole frame inside the selected `visibleFrame`; negative screen coordinates
are valid. On first display placement with no saved frame, use the pointer's
screen, then the main-window screen, then `NSScreen.main`, then the first
screen. On `didChangeScreenParameters`, re-run the saved-frame containment,
overlap, fallback, and whole-frame clamp rules. Never reset placement merely
because a phase changed.

The toast exposes AX role, stable status label, current value, and live
announcement for each phase/action. Mouse dragging remains available and
Settings exposes a `Reset Position` action. Reduce Motion dismisses directly
without fade and removes nonessential animation. Reduce Transparency uses an
opaque readable surface. Increase Contrast strengthens border and text
contrast. Permission/model failures expose their Retry, Download, Remove, or
settings-recovery action to VoiceOver.

## Permissions, Settings, and Toast Copy

Permission state is explicit: unknown/requesting, granted, denied, and
restricted/unavailable. Denied or unavailable states show the supported macOS
settings recovery action plus Retry/Recheck; recovery never silently restarts
recording or changes caption permission.

Modify only the existing settings screens. Controls and states are exact:

- Dictation cleanup: Toggle, default off.
- Dictation recognizer: Picker for the existing streaming Nemotron/Parakeet
  choice; it remains distinct from Whisper batch selection.
- Whisper model: Picker with `openai_whisper-base.en` and
  `openai_whisper-small.en`, each showing the real
  WhisperKit readiness state and Download/Retry/Remove action.
- Captions: row that navigates to actionable caption readiness controls; it is
  not a duplicate or fake readiness indicator in Dictation settings.
- Permission recovery: explicit state, settings action, and Retry/Recheck.

Use these concise toast phase copies: `Allow Dictation Permission`,
`Preparing Dictation`, `Ready to Dictate`, `Recording`,
`Transcribing`, `Cleaning`, `Translating`, `Inserting`,
`Copied to Clipboard`, `20-Second Limit Reached`, and
`Dictation Failed: Retry`.

## Test Matrix

Add only coverage absent from current generation-guard,
`finishDictation()`, authoritative-final, and partial-download tests.

| Area | Required assertions |
| --- | --- |
| Cleanup contract | Separate system/user prompts; trim and reject empty, fenced, and surrounding-prose output; error/timeout/nil/invalid output uses original and continues. |
| Cleanup ordering | Cleanup receives only authoritative text; translation follows selected result; one insertion/clipboard operation occurs. |
| Cancel/new generation | Cancel and new generation discard all output and prevent insertion; late cleanup/translation cannot update phase. |
| Streaming independence | Captions remain streaming Nemotron/Parakeet; their pool and settings remain independent of Whisper batch state. |
| Whisper ownership | Exactly `openai_whisper-base.en` and `openai_whisper-small.en`; readiness/actions come from WhisperKit state; `ModelRegistryTests` continue to exclude Whisper. |
| Audio cap | Only successful 16 kHz mono samples count; sample 320000 stops capture and enters transcription; conversion failures do not count; captions are unaffected. |
| Terminal race | First accepted cap/release/cancel transition wins; cancel wins only if accepted first; drain and finalization happen once. |
| Toast placement | Independent key, saved-frame center containment, maximum overlap fallback, pointer/main-window/main/first-screen order, negative coordinates, display change, whole-frame clamp, and phase stability. |
| Accessibility | AX role/status/value/live announcement, Reset Position, Reduce Motion direct dismiss, opaque Reduce Transparency, and Increase Contrast boundaries/text. |
| Settings | Exact toggle/pickers/actions/states, actionable Captions navigation, permission recovery, and exact phase copy. |

## Acceptance Criteria

The implementation is macOS-only and local-only, cleanup is off by default,
and partials are never processed. `openai_whisper-base.en` and
`openai_whisper-small.en` are the only
Whisper choices, with WhisperKit owning download/cache integrity and no
Whisper `ModelAsset`. Captions remain streaming Nemotron/Parakeet through the
shared pool, while dictation rejects overlap. Authoritative text, optional
cleanup, optional translation, and one final insertion follow the stated
fallback and generation rules. The 320000-sample cap, serialized terminal
transition, independent persistent accessible toast, exact settings controls,
and focused test matrix are explicit. No global navigation, new window
system, gradient/fading background, speculative abstraction, or release claim
is introduced.

Before commit, inspect the full document for unresolved wording and run
`git diff --check`. This spec change records no test result.
