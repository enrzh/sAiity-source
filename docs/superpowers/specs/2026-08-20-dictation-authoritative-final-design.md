# Dictation Authoritative Final Transcript Design

## Goal

Make press-to-talk dictation insert the recognizer's authoritative completed
utterance, so a late correction to an early streaming hypothesis reaches the
focused app. Preserve the current rolling-commit behavior for live captions and
make Hy-MT2 sampling conservative enough for translation rather than creative
generation.

## Current Root Cause

`StreamingASRBackend` serves both captions and dictation. Its partial callback is
cumulative, but it emits stable-looking `isFinal` chunks as captions need them:
punctuated sentences, rolling phrase commits, and the tail flushed at silence.
Those rolling commits are intentionally allowed to be early because captions
must keep up with continuous speech.

`DictationController` currently collects only those `isFinal` chunks. On release
it calls `flushPending()` and `stop()`, but it does not consume the full result
returned by the underlying engine's `finishSession()`. If the engine revises an
early phrase after a rolling commit, the controller has already retained the
old wording and inserts it.

## Decision

Add a dictation-specific completion boundary to `TranscriptionBackend`:

```swift
func finishDictation() async -> String?
```

The method returns the engine's authoritative completed utterance when the
backend can provide one. It owns the active backend session's finalization and
resets the loaded backend for reuse, but it does not emit the authoritative text
through the caption callback.

`StreamingASRBackend.finishDictation()` will:

1. stop and await the single processing pump;
2. discard any unprocessed queue state using the same teardown boundary as
   `stop()`;
3. call `FluidStreamingEngine.finishSession()` once;
4. reset the engine and clear the session callback while retaining loaded model
   resources; and
5. return the complete transcript from `finishSession()`.

`StreamingASRBackend.stop()` remains the caption path. It continues to emit only
the uncommitted suffix from `finishSession()`, preserving rolling commits,
caption timing, and translation cadence.

The protocol extension supplies a compatibility fallback that flushes and stops
the backend and returns `nil`. `DictationController` uses the authoritative
value when it is non-empty and falls back to its existing final-chunk collector
when a backend cannot provide one. This keeps dictation functional for simple
test or future backends without weakening the production streaming backend's
authoritative path.

## Controller Data Flow

On press, the controller continues to collect final chunks because the callback
is still needed by the shared backend lifecycle and provides a fallback.

On release:

1. stop the microphone immediately;
2. set the phase to `transcribing`;
3. call `finishDictation()` exactly once;
4. choose the returned authoritative text if it is non-empty, otherwise use the
   collected rolling finals;
5. translate the chosen whole utterance when dictation translation is enabled;
6. insert or copy the resulting text; and
7. leave the prepared backend available for the next press.

The controller must not call `flushPending()` and then `stop()` before
`finishDictation()`, because that would reintroduce an early rolling final as
the primary dictation result. A cancelled or superseded generation must still
discard the returned text before translation or insertion.

## Hy-MT2 Sampling

Keep Hy-MT2's existing model template, prompt, validator, language set, and
whole-sentence translation flow. Change only generation temperatures:

- first generation: `0.1`;
- retry after a validator-retryable rejection: `0.15`.

The retry remains slightly warmer than the first attempt so it can escape a
bad deterministic continuation, while both values are far below the current
`0.7` and `0.9` settings. `topP`, `topK`, repeat penalty, context limit, and
the MADLAD recommendation remain unchanged.

Whole-sentence translation remains the quality-first default. No live or
fragment translation is introduced by this change.

## Error Handling and Invariants

- Caption `stop()` continues to emit rolling commits and only its uncommitted
  suffix; existing caption timing and translation behavior are unchanged.
- Dictation insertion prefers one authoritative utterance and never concatenates
  an early rolling hypothesis with the authoritative result.
- An empty or unavailable authoritative result falls back to the collected
  final chunks; an entirely empty result still produces `No speech detected`.
- The backend's engine `finishSession()` is called at most once per dictation
  session.
- The loaded model remains reusable after dictation completion.
- Cancellation and generation checks continue to prevent stale output from
  reaching translation or insertion.
- No transcript-store writes, microphone-lifecycle changes, or UI changes are
  part of this work.

## Tests

Add a controller regression test with a fake backend that emits an early rolling
final such as `Schedule a meeting with Sara` and later returns the authoritative
completion `Schedule a meeting with Sarah.`. Assert that insertion receives only
the revised completion and that `finishDictation()` is used.

Add backend tests that assert:

- `finishDictation()` returns the underlying engine's full completion without
  emitting it as a caption final;
- caption `stop()` still emits the uncommitted suffix from the same engine; and
- the backend can be started again after dictation completion without loading
  the model a second time.

Add a Hy-MT2 configuration assertion for the two generation temperatures so the
quality-first sampling contract cannot drift back to the old values. Existing
prompt, validator, language, and recommendation tests remain unchanged.

## Scope

In scope: `TranscriptionBackend`, `StreamingASRBackend`,
`DictationController`, their focused tests, and Hy-MT2 generation constants.

Out of scope: changing caption rolling-commit thresholds, changing translation
timing defaults, changing model selection, adding a new ASR engine, changing
the microphone or insertion behavior, or cutting a release.
