# sAiity

Live subtitles for **anything playing on your Mac** — a video, a call, a stream —
recognised and translated entirely on-device. No account, no API key, no network.

Menu-bar app (no Dock icon). Captions render in a floating, click-through bar at
the bottom of the screen that follows you across Spaces and stays visible over
full-screen video.

## Status

Route A (all-Apple) is built and verified end-to-end.

| Piece | State |
|---|---|
| System-audio capture (ScreenCaptureKit) | working — 0.00 s drift over 180 s |
| Streaming recognition (`SpeechAnalyzer`) | working — ~1 s behind live, updates ~1×/s |
| Liquid Glass bubble (`NSGlassEffectView`) | working |
| Draggable, position remembered | working — drags pixel-exact, never steals focus |
| Copy button + copy whole session | working |
| Transcript memory (meetings) | working — opt-in, local-only |
| Export txt / md / srt, incl. CLI | working — word-level SRT cues |
| Language picker — all 45 locales, 25 groups | working |
| Automatic language detection | working — on by default |
| Main window (languages / transcripts / settings) | working |
| Model download + 5-slot allocation cap | handled |
| Silence / stream-death detection | working |
| On-device translation (`Translation`) | wired; needs a language pair installed |

Verified transcript, spoken German → screen, warm engine:

```
09:53:09.909  Die
09:53:10.869  Die Live Untertitel
09:53:12.786  Die Live Untertitel laufen jetzt vollständig auf dem Gerät
09:53:15.674  … Es werden keinerlei Daten an einen Server gesen
09:53:17.597  … Alles bleibt lokal auf        ← speech ended 09:53:17.3
09:53:18.590  FINAL: Die Live Untertitel laufen jetzt vollständig auf dem Gerät.
              Es werden keinerlei Daten an einen Server gesendet.
              Alles bleibt lokal auf dem Mac
```

## Build & run

```bash
./build-app.sh --install
```

```bash
/Applications/sAiity.app/Contents/MacOS/sAiity --export srt > meeting.srt
```

Builds `build/sAiity.app`, copies it to `/Applications`, and registers it with
Launch Services so it appears in Finder, Spotlight and Launchpad. Drop
`--install` to build only.

**First run needs Screen Recording.** That is how macOS gates system-audio
capture — there is no audio-only permission. Click *Start captions*, allow
sAiity in System Settings → Privacy & Security → Screen Recording, then relaunch.

> Running the binary straight from a terminal appears to work without granting
> anything, because the child process inherits the terminal's grant. That is not
> representative — test via Finder, where the app correctly reports no permission.

## The window

`Open sAiity…` in the menu, or just double-click the app — an agent app otherwise
does nothing when launched, which reads as broken, so re-opening brings the window
up. Four tabs:

- **Languages** — all 45 speech models grouped by language, install state, and a
  Download button with progress for the rest. Shows slot usage (`n/5`), because
  macOS caps allocated locales. There is **no API to delete a model** — the whole
  of `AssetInventory` is reserve / release / status / maximumReservedLocales — so
  the window says removal happens in System Settings rather than pretending.
- **Transcripts** — saved sessions with date, line count and language, total disk
  usage, and per-session export to SRT/Markdown, reveal, or delete.
- **Settings** — automatic language detection, reset bubble position, save
  transcripts, launch at login.
- **Status** — which on-device models are present, Apple Intelligence
  availability, Screen Recording permission, and a plain statement that nothing
  leaves the Mac.

**Launch at login** works once the app is signed with a real identity (see
Signing). `SMAppService.mainApp.status` reports `.notFound` before the first
registration — that is normal, not a failure, and treating it as one was a bug:
registering flips it straight to `.enabled`. Verified both directions,
`request=true → status=enabled`, `request=false → status=notRegistered`.

## The bubble

A borderless Liquid Glass panel that floats over everything, including
full-screen video. **It sizes itself to the caption in both axes** — the text is
measured unwrapped, clamped between a floor that keeps the corner controls clear
of the words and the screen-derived ceiling, then the height is measured at that
width. Growth is symmetric about the centre and the top edge stays put, so a
bubble you have placed does not walk around as captions change length. Controls
sit hard in the corners — status left, copy right — because anything drifting
toward the middle competes with the caption itself. It is **click-through where the text is**, so it never eats a
click meant for what you are watching. Hover it and a control strip fades in
along the top: a drag grip on the left, a copy button on the right, and a red dot
while a transcript is being recorded. Drag it anywhere; the position is saved and
clamped back onto a real screen when you dock or undock.

That combination needs care, because two facts collide:

- `ignoresMouseEvents` is a **whole-window** property. A window cannot be
  click-through in one region and interactive in another. Returning `nil` from
  `hitTest` does *not* pass the click through — it swallows it. Neither does a
  fully transparent pixel; there is no alpha-based hit testing.
- An `NSTrackingArea` with `.activeAlways` **keeps firing while the window is
  click-through**, and while the app is inactive.

So the bubble tracks hover for free and flips `ignoresMouseEvents` to `false`
only while the cursor is over the top strip (armed 12 pt early, to cover a
measured few-ms race between the toggle and the click). Movement goes through
`performDrag(with:)`, which works even with `isMovable = false` — that kills
accidental background drags while keeping the window-server drag session.

Verified: dragging and clicking the bubble leaves the frontmost app untouched —
`isKeyWindow` false, `NSApp.isActive` false, and a real app's titlebar stayed
pixel-identical across both.

**Option-drag is not used deliberately.** It is macOS's own window-tiling
accelerator; letting it through relocates the bubble to a screen edge on mouseUp.

## Meeting memory

`Save transcript` — **off by default** — writes each Start→Stop cycle to
`~/Library/Application Support/de.aiity.saiity/Sessions/<timestamp>/`
(`0700` dirs, `0600` files) as `meta.json` plus append-only `segments.jsonl`.
Appending is O(1) through one long-lived file handle, so a two-hour meeting costs
nothing per line.

The menu lists past sessions with date, line count and duration, and each one can
be copied, exported to Markdown or SRT, revealed in Finder, or deleted. Deletion
removes the directory — no tombstone.

Also scriptable:

```bash
/Applications/sAiity.app/Contents/MacOS/sAiity --list
/Applications/sAiity.app/Contents/MacOS/sAiity --export srt > meeting.srt
```

**Only finals are stored.** Volatile results are cumulative *since the last
final* — one observed volatile spanned four sentences and 15 seconds — so
persisting them would duplicate whole paragraphs. Consecutive finals are already
non-overlapping and monotonic, which means the store needs no de-duplication at
all.

**Word timings make SRT usable.** The backend asks the engine for
`.audioTimeRange` and now keeps it (`run.audioTimeRange` over `result.text.runs`,
plus `result.range` for the segment). Without that, one 11-second final would be
one unreadable cue. With it:

```
1
00:00:18,660 --> 00:00:22,620
Guten Morgen zusammen, der erste Punkt ist die Budgetplanung.

2
00:00:22,620 --> 00:00:25,020
Enrico stellt gleich die Zahlen vor.

3
00:00:25,020 --> 00:00:29,820
Danach sprechen wir über den Einstellungsplan für das nächste Quartal.
```

### Recording is a different thing from captioning

Live captions are ephemeral; a transcript is a durable written record of a
conversation other people were part of. So recording is a separate opt-in toggle,
default off, and the state is deliberately hard to miss: the menu-bar icon fills
in, the menu leads with `● Recording · 12 min · 84 lines`, and a red dot sits on
the caption bar itself. Everything stays on this Mac — no sync, no analytics.
System audio includes everyone on the call, and they have no idea a transcript is
being written; recording other people may require consent or be regulated where
you are.

## Languages

The menu lists **every locale the engine supports** — 45 here, grouped into 25
languages and named in their own script (Deutsch, 中文, 日本語, हिन्दी, தமிழ், …).
A `✓` marks models already on disk; anything else downloads on first use, with
percentage progress in the menu.

This machine ships 45 supported but only **3 installed** — de-AT, de-CH, de-DE —
so the app defaults to an installed locale rather than stalling on a
several-hundred-MB fetch at first launch.

**The allocation cap.** `AssetInventory.maximumReservedLocales` is **5**, and
`assetInstallationRequest` *implicitly reserves a slot for the locale it is asked
about* — merely checking burns one, permanently, until released. A menu that
probed all 45 would throw `SFSpeechErrorDomain` code 11 ("Too many allocated
locales") with no download ever attempted. `SpeechModels.releaseAllExcept`
therefore frees every other reservation before each request, keeping us at
exactly one slot however many languages you cycle through. Code 11 has no
symbolic constant — `SFSpeechErrorCode` does not declare it — so it is matched
on the raw value.

Translation covers a separate set of 41 languages, and a pair must be downloaded
once in System Settings → General → Language & Region → Translation Languages.
The framework cannot raise that prompt from a menu-bar app, so the menu says so
instead of hanging.

## Automatic language detection

`Language → Automatic`, **on by default**. The detected language is always tracked
and shown in the menu; the toggle controls whether it also **switches** the
recogniser. Picking a language by hand turns it off, so an explicit choice is
never overridden a few sentences later — and the off state persists (the default
is supplied via `register(defaults:)`, so a stored preference always wins).

There is no public spoken-language API to build this on. `SpeechTranscriber` takes
exactly one locale, and no `Result` type carries a language. Apple *has* built
`Speech.LanguageDetector` — it is in the framework binary, with
`detectedLanguageCode`, `dominantLocale` and per-locale confidences — but no
`.swiftinterface` declares it, so it cannot be imported. Worth re-checking each
OS release.

**`.transcriptionConfidence` does not work for this, measured.** Across 26
utterances and 6 voices per language: German-into-German scored 0.718–0.996,
English-into-German 0.474–0.889. Overlapping. Confidence tracks *audio and speaker
quality*, not language — a crisp English speaker outscores a mumbling German one.
The best operating point still misclassified an utterance on clean synthetic
speech, with a threshold window ~0.09 wide that a real microphone would close.
It also only exists on final results, so it can never be read from live captions.

**`NLLanguageRecognizer` over the emitted text does work** — 26/26, p ≥ 0.98.
The gates in `LanguageDetector.swift` come from where it actually fails:

| Case | Result | Consequence |
|---|---|---|
| `"Ja."` | Finnish p=0.59 | single lines are noise → `minCharacters` |
| `"Okay."` | English p=0.39 | " |
| `"23. April 2026."` | Dutch p=0.37 | numbers/names are language-neutral |
| `"RE20262933."` | Czech p=0.15 | " |
| German full of English loanwords | German **p=1.000** | the expected failure that wasn't |
| Accumulated transcript | p=1.000 from ~50 chars | so detect on accumulated text |

It also survives the bootstrap case, which matters because you may start on the
wrong model: garbled German produced *by an English model* still reads as German
at p=1.000, and garbled English from a German model as English at p≥0.993. So it
recovers rather than locking in the mistake.

Windowing is by **recent lines**, not a character budget. A character window does
not evict anything until it overflows, so the opening language of a session keeps
outvoting the current one — measured: three English sentences after one German
one still read as German. Verified end to end: German with *Meeting, Deadline,
Feature Release, Product Owner, Standup, Team* stayed `de`, then sustained English
flipped to `en`.

Two limits worth stating:

- Detection can only ever choose among **installed** models, and macOS caps you at
  5 allocated locales. So it is "auto-detect among the languages you have", not
  "auto-detect any of the 45".
- Switching often is not needed at all. The `de-*` and `en-*` transcribers share
  one multilingual model — verified, they return byte-identical text and
  confidence — and English audio transcribes verbatim-correct through a German
  locale. The locale behaves more like a decoding hint than a model selector.
  So a switch only fires when a model for the detected language is genuinely
  installed *and* differs from the current one — otherwise detection just updates
  the status line. The detected language is also used as the **translation
  source**, which the selected locale would otherwise get wrong.

## When there is no sound

Measured, not assumed:

- **Nothing playing** — ScreenCaptureKit keeps delivering buffers *forever* at
  exactly real time (50/s, 960 frames, 48 kHz mono Float32) and every sample is
  bit-exact zero: 0 nonzero out of 7,432,320 samples over a 154 s soak. The
  transcriber emits nothing. So "buffers are arriving" proves nothing, and the
  old UI sat on `listening…` indefinitely — indistinguishable from a dead
  pipeline. The app now measures peak magnitude per buffer with vDSP and shows
  **"nothing is playing"** after 2 s of digital silence.
- **The real failure is the inverse.** A healthy stream fires ~50×/s even in
  total silence, so buffers *stopping* is the actual error. A watchdog flags it
  after 1.5 s rather than letting it look like quiet.
- **Muting the Mac does not stop capture.** The SCK tap sits upstream of the
  output device's volume and mute stage. A source peaking at 0.5 was captured at
  0.49999687 at volume 25 unmuted *and* at volume 0 while muted — bit-identical,
  same nonzero-sample count. sAiity keeps transcribing and translating audio you
  cannot hear. Only *Stop captions* stops it. This was confirmed twice, by
  independent tests.

Sensitivity for reference: a source at −60 dBFS peak still produced a complete,
correct transcript, so the silence threshold (1e-7) sits far below any real signal.

## Signing

`build-app.sh` picks the best identity available, in order:

| Identity | What you get |
|---|---|
| **Developer ID Application** | Runs on other Macs (after notarisation). Required for distribution. |
| **Apple Development** | Local use. Launch-at-login works. Screen Recording permission **survives rebuilds**. |
| ad-hoc (no certificate) | Works locally, but TCC keys on the cdhash, so Screen Recording resets on **every rebuild**. |

That middle row is the one that matters day to day: an ad-hoc signature has no
Team ID, so its designated requirement is a bare `cdhash`, and any change to the
binary is a different app as far as TCC is concerned. A real identity makes the
permission stick.

Signing uses hardened runtime and a secure timestamp — both required for
notarisation, harmless before it.

Override with `SAIITY_SIGN_ID="Developer ID Application: …"`, or `SAIITY_SIGN_ID=-`
to force ad-hoc.

### Distributing to another Mac

A locally built app is never quarantined, so it launches fine here regardless.
Copied to another Mac it *is* quarantined, and Gatekeeper needs a Developer ID
signature plus notarisation:

```bash
xcrun notarytool store-credentials "saiity" --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
```

```bash
./build-app.sh --notarize
```

The credential profile is created once, by you — no secret passes through the
build script.

## Architecture

```
ScreenCaptureKit ──► AVAudioConverter ──► TranscriptionBackend ──► OverlayWindow
 (system audio)      (48 kHz → engine)     (protocol)               (NSPanel)
       │                                        │
   vDSP peak                                    └──► Translator (on-device)
  (silence/stall)
```

- `TranscriptionBackend.swift` — the seam. `prepare / start / feed / stop`, plus
  a `TranscriptChunk { text, isFinal }`. Everything else is engine-agnostic.
- `AppleSpeechBackend.swift` — `SpeechTranscriber` + `SpeechAnalyzer`.
- `LocaleCatalog.swift` — locale grouping, model download, the allocation cap.
- `SystemAudioCapture.swift` — SCK capture, resampling, silence + stall detection.
- `OverlayWindow.swift` — the glass bubble, hover/drag, frame persistence.
- `TranscriptStore.swift` — session recording, listing, deletion.
- `Export.swift` — clipboard, txt/md/srt serialisers, cue splitting.
- `LanguageDetector.swift` — spoken-language detection with its measured gates.
- `Translator.swift` — `TranslationSession`, finals only.
- `AppDelegate.swift` — menu bar, pickers, rendering.

`SAIITY_AUTOSTART=1` starts capture without a click and logs every chunk, every
capture-state change, and captured-vs-delivered audio seconds — that is how the
timings here were measured.

## Bugs worth remembering

**Double-consuming the input stream → hard crash.** `SpeechAnalyzer` has two
initialisers. `init(inputSequence:modules:)` *already* starts reading the
sequence; calling `start(inputSequence:)` on top of it attaches a second consumer
and traps inside `SpeechAnalyzer.analyzeSequence` (SIGTRAP, exit 133). Use
`init(modules:)` **or** the inputSequence initialiser, never both.

**`.volatileResults` alone is not live.** With only `.volatileResults` the engine
batched a whole utterance and delivered it in a single burst ~3.6 s *after* speech
ended — accurate, but useless as captions. Adding **`.fastResults`** is what makes
results stream during speech. Both are needed.

**Volatile results are cumulative for the current utterance** — they grow from
`"Die"` to the full sentence. Appending them to the previous final prints the
sentence twice.

**`NSPasteboard.setString` fails silently without `clearContents()`.** It returns
`false` and writes nothing — `clearContents()` is what takes ownership of the
pasteboard, not a tidiness step.

**An opaque window kills Liquid Glass.** A borderless panel defaults to
`isOpaque = true`, which renders `NSGlassEffectView` as a flat dark rectangle with
no error and no log line. `isOpaque = false` + `backgroundColor = .clear` are
load-bearing. Content must also go through `glass.contentView` — views added with
`addSubview` are not clipped by `cornerRadius`, and `clipsToBounds` does not fix
it.

**`Translation` needs a real app bundle.** In a bare command-line binary even
`LanguageAvailability.status` never returns — the framework talks to a per-app
daemon over XPC. Inside the `.app` it answers instantly.

## Other local engines

The backend protocol exists so these can slot in without touching capture or UI.
All are proven on Apple Silicon by [ghost-pepper](https://github.com/matthartman/ghost-pepper):

| Engine | Model | Notes |
|---|---|---|
| **WhisperKit** | CoreML Whisper | 99 languages, SwiftPM, no cmake. Batch-shaped — needs sliding windows + seam de-dup to fake streaming. |
| **FluidAudio** | Parakeet v3 | 25 languages, ~1.4 GB, strong accuracy. |
| **MLX Audio** | Nemotron streaming | Built for low latency. |
| **LLM.swift** | Qwen | For translation/summarising rather than ASR. |

Apple's transcriber was chosen first precisely because it streams natively —
faking streaming on a batch model is the single biggest source of latency and
stutter in tools like this.

## Why there is no Dock icon

`LSUIElement` is `true`: sAiity is an agent app, so it has no Dock icon, no
Cmd-Tab entry and no application menu. Its entire UI is the menu-bar item and the
caption bar. It *does* appear in Finder, Spotlight, Launchpad and Activity
Monitor once installed to `/Applications`. Removing that key would give it a Dock
icon and a Cmd-Tab entry, at the cost of behaving like a window app that has no
windows.

It is ad-hoc signed (`Signature=adhoc`, no Team ID). Locally that is fine —
Gatekeeper's launch assessment only runs against bundles carrying
`com.apple.quarantine`, which a locally compiled app never has. Copying it to
another Mac would be quarantined and rejected; that needs Developer ID signing
and notarisation.

## iOS

The recognition and translation layers port as-is: `SpeechAnalyzer`,
`SpeechTranscriber`, `AssetInventory` and `Translation` are all
`@available(anyAppleOS 26, *)` — the same code compiles for iOS 26.

What does **not** port is the audio source. `ScreenCaptureKit` is macOS-only and
iOS has no equivalent: an app cannot capture other apps' audio. iOS is limited to

- the **microphone** (`AVAudioEngine`) — captions for the room, in-person
  conversation, a lecture, a meeting;
- **audio your own app plays** — a media player or file importer that subtitles
  its own content;
- **ReplayKit** broadcast — system audio, but only inside a user-started
  broadcast session, not as an ambient overlay.

The floating always-on-top bar is also macOS-only; on iOS captions would live in
the app itself or in a Live Activity.

So: an iOS version is real, and most of this code moves over unchanged — but it
is a *microphone* captioner, not a system-audio one. Everything below
`TranscriptionBackend` is already portable; only `SystemAudioCapture` would be
swapped for an `AVAudioEngine` source.
