# Dictation Translation and Startup Feedback Design

**Release target:** 2.2.0

## Goal

Make dictation translation an independent, understandable setting and remove the first-words race caused by loading the ASR model only after the push-to-talk shortcut is pressed.

## Current State

- Dictation translation already exists, but its target is read from the captions preference `translateTo`.
- The dictation page shows a translation toggle but no independent language selector.
- The status-item menu has one translation submenu, so it is ambiguous whether a language applies to captions or dictation.
- The dictation shortcut is registered before the ASR backend is prepared. The controller creates and prepares a new backend inside `press()`, while the toast already says it is ready.
- The existing toast is a cross-app floating panel and already has the required ready, active, processing, result, and error presentation behavior.

## Decisions

### Independent dictation target

Add `AppState.dictationTranslateTo` backed by its own UserDefaults key. The first time this preference is initialized, copy the current captions target once and persist a migration marker, including the off state. From that point forward, changing either target changes only that target.

Dictation translation remains off by default. If a user enables it after the one-time migration and the inherited target was off, the page presents the language selector so the user can choose a target before speaking.

The dictation controller receives the dictation target, never the captions target. The translation engine remains shared, but the target and opt-in flag are separate. Translation is still lazy and runs after speech is released; the large translator model is not loaded merely because the dictation page is open.

### Settings page

The Dictation page keeps the existing opt-in toggle and adds a `Language` control below it. The control is disabled while dictation translation is off, shows the independent selected language, and opens the existing searchable language picker using a binding to `dictationTranslateTo`. The picker must retain one language catalog and one support check rather than maintaining a second list for dictation.

The explanatory copy explicitly says that dictation has its own target and does not follow captions after the first setup migration.

### Status-item menu

Replace the ambiguous single translation item with two clearly scoped submenus:

- `Captions: Translate to`
- `Dictation: Translate to`

Both use the same menu-building helper and language catalog. Each submenu has its own Off state, current target, recent targets, preferred languages, and `All languages...` action. The all-languages action opens the same searchable picker with the correct target binding. Selecting a dictation language writes only `dictationTranslateTo`; selecting a captions language keeps the existing captions notification and translator behavior.

### ASR prewarm and truthful readiness

Extend `DictationController` with a preparation lifecycle:

- `preparing`: the model is downloading or loading; the toast says `Preparing Dictation...` and stays visible.
- `ready`: the shortcut is registered and the prepared backend has a valid input format; the toast says `Ready to Dictate - Hold <chord>` and may fade after its inactivity timeout.
- `starting`: a press has arrived and the controller is starting the streaming backend and microphone; the toast says `Starting Dictation...`.
- `dictating`: capture is active and speech is being fed to ASR.

When dictation is enabled and Input Monitoring is available, the app starts preparation immediately after registering the shortcut. The controller retains the prepared backend between short sessions, so a press uses the already-loaded model instead of constructing and loading a new one. A session still calls the backend's normal `start` and `stop` lifecycle, so pending audio and final text are isolated per press.

If the user presses before preparation completes, the toast remains truthful and the controller waits for preparation before starting capture. The first words spoken before the `ready` hint cannot be guaranteed to be captured; the primary fix is to make the readiness boundary visible before the user speaks.

The prepared backend is invalidated when dictation is disabled, the recognition engine or Nemotron tier changes, the app releases models for deletion, or cancellation tears down an in-flight preparation. A failed preparation clears the cached backend and reports the error; the next shortcut press or enable event can retry.

The translator is not prewarmed as part of shortcut readiness. Its model is substantially larger and dictation translation begins only after release, so loading it at app launch would make startup and memory usage worse. Its existing fallback still inserts or copies the original dictated text when translation is unavailable.

## Data Flow

1. App launch or dictation enable registers the global chord.
2. The controller enters `preparing`, creates the selected ASR backend, downloads missing weights if necessary, and calls `prepare`.
3. Once `inputFormat` is available, the controller stores the backend and emits `ready`; the toast is positioned above the current frontmost app.
4. A press enters `starting`, calls `backend.start`, and opens the microphone capture using the prepared format.
5. A successful capture start enters `dictating`. Final recognizer chunks accumulate as before.
6. Release stops capture, flushes and stops the backend session, optionally translates using `dictationTranslateTo`, then inserts or copies the result.
7. The loaded backend remains available for the next press. It is released only through the invalidation paths above.

## Error Handling and Invariants

- `ready` is never emitted before backend preparation and input-format resolution succeed.
- A backend preparation task is single-flight; enabling dictation twice or receiving repeated permission retries cannot load two ASR models.
- A release that arrives during preparation waits for the same preparation task and then finishes the session without opening a second backend.
- A cancelled or superseded preparation cannot install its backend into a newer session.
- Dictation never changes captions' target, translation timing, transcript storage, or microphone-mixing setting.
- Caption model deletion releases the warmed dictation backend before removing files.
- No microphone is opened during prewarm; the microphone starts only after a valid push-to-talk press reaches `starting`.
- Translation failure never discards the original dictated text.

## Testing and Verification

Add tests before implementation for:

- one-time inheritance of the current captions target and subsequent independent persistence;
- separate dictation and captions targets in the controller configuration;
- preparation emitting `preparing` then `ready`, reusing one backend across two presses, and avoiding a second `prepare` call;
- a press before readiness showing `starting` and beginning capture only after preparation;
- invalidation releasing the prepared backend and allowing a fresh preparation;
- menu helper state/target selection for the two scopes where AppKit can be tested without launching the full app.

Run the repository's supported release test command:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Build the release app with the existing release script, launch the resulting app with its settings test hook, and inspect screenshots of the Dictation page and status-item submenus. Verify that the ready toast appears only after preparation and that the settings language control is readable and independent from Captions.

## Release Scope

The release is `v2.2.0`. It includes the independent dictation translation settings, scoped menu controls, truthful ready feedback, ASR backend prewarming/reuse, regression tests, updated localized strings, and the existing notarized macOS release artifacts. No Windows work or new translation engine is part of this release.
