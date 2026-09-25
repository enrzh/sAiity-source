# sAiity 2.0 — Windows and caption quality

Written 2026-08-14, against v1.3.0. Everything here is grounded in a research
pass over the current tree and the current state of the relevant projects;
where something is unverified it says so, because the difference between
"verified" and "sounds right" is the difference between a quarter and a year.

---

## The one-paragraph version

The Windows port is far less risky than it looks, because the exact ASR model
sAiity already ships now runs cross-platform. The genuinely hard, unresolved
question on Windows is not recognition — it is whether the caption bubble can
be click-through **and** have a blurred background at the same time. Answer
that with a half-day spike before committing to anything else. On macOS, the
current product intentionally keeps processing local and minimal: recognition,
translation, transcripts, and the live subtitle bubble.

---

## Part 1 — Features (Mac first)

### 1. Speaker identification — removed from the product

The earlier diarization experiment is no longer part of sAiity. It added a
second model, another inference pass, extra settings, and a misleading promise
about knowing who spoke. The app now keeps the simpler local path: recognition
and translation, with turn breaks only when the audio clock shows a real pause.
Old transcript metadata is retained for safe decode/re-encode compatibility,
but no new labels are produced or displayed.

### 2. Summarise a session — nearly free

`LLM.swift` is already a dependency and a GGUF model is already shipped as
translator #2. A one-shot "summarise this transcript" — TL;DR, decisions,
and action items — is mostly prompt work
and a map-reduce for long sessions that will not fit a small local context.

This is the feature that changes what the app is *for*: from "I can read what
was said" to "I do not have to."

### 3. Caption output — the audience multiplier

Push captions outward: a localhost page consumable as an **OBS browser
source**, and Zoom's third-party closed-caption API (the host generates a URL,
the app POSTs to it). This turns a personal accessibility tool into "caption
this meeting for everyone."

**This is the one feature that sends text off the machine.** The consent UI has
to be explicit and per-session, or it breaks the promise the whole app is built
on. Treat Teams as best-effort; its CART ingestion has poor public reliability
reports.

### 4. Glossary — if the schedule holds

Names, product names, jargon. **Not** acoustic biasing: FluidAudio's
`CustomVocabularyContext` exists but is wired only into the Parakeet CTC path,
not the Nemotron streaming manager sAiity actually runs. Do it as a text layer
instead — fuzzy correction on committed sentences plus do-not-translate terms
injected into the translator. Cheaper, and it solves the actual complaint
("it keeps spelling my company wrong").

### Deliberately not in 2.0

| Idea | Why not |
|---|---|
| Real participant names from Zoom/Teams | No supported route. Zoom exposes active speaker on the iOS SDK only, absent on macOS. Would be a scraping hack that breaks. |
| iOS/iPadOS companion | The premise does not exist there: no ScreenCaptureKit equivalent, and the only app-audio route is a ReplayKit extension under a ~50 MB memory cap. These models do not fit. |
| Subtitle burn-in / virtual camera | Burn-in is a video editor's job and SRT/WebVTT already feed every NLE. Virtual camera needs a Camera Extension and a whole new permission story. |
| Multi-target translation (>2–3) | Costs more than intuition suggests — MADLAD's target token goes into the *encoder* input, so each target is a full re-encode, not a cheap decoder swap. Cap at 2–3, sentence mode only. |

---

## Part 2 — Windows

### What changed since the last time this was estimated

The ASR swap was assumed to be the schedule risk. It is not.
`nvidia/nemotron-3.5-asr-streaming-0.6b` — the same checkpoint sAiity ships via
FluidAudio's CoreML port — now has first-class ONNX support in **sherpa-onnx**
(k2-fsa, Apache-2.0), including the multilingual variant with the
`prompt_index` language-conditioning input (merged June 2026; re-export shipped
in v1.13.5, 2026-08-11). At least one cross-platform desktop app already ships
it on Windows, CPU-only, with partial results well under a second behind
speech.

That means: **same weights, same languages, same transcript behaviour on both
platforms.** One product story, not two.

### The real risk: click-through vs. acrylic

Cross-process click-through on Windows requires `WS_EX_LAYERED` together with
`WS_EX_TRANSPARENT` — `WM_NCHITTEST`/`HTTRANSPARENT` only falls through within
the same thread, which is useless for an overlay sitting over a browser.

And `WS_EX_LAYERED` is exactly the style that fights DWM's Mica/Acrylic
backdrops. Community evidence (Electron, WPF-UI, wezterm) says backdrops
degrade or vanish on layered windows. **No definitive answer was found.**

> **Spike this first — half a day, before any other Windows work.**
> E1: non-layered window + `DwmSetWindowAttribute` backdrop → confirm acrylic.
> E2: add `WS_EX_LAYERED` → does the backdrop survive?
> If it does not, the fallback is a solid or self-blurred background for the
> Windows bubble. That is an acceptable product answer; discovering it in month
> three is not.

### The stack

| Layer | Choice | Note |
|---|---|---|
| Shell | **WPF on .NET 10 + WPF-UI** | The overlay is ~90% Win32 interop whatever you pick; choose the framework with the best interop story and the most prior art. Settings/transcripts get Windows 11 look for free. |
| Overlay | Raw Win32 | `WS_POPUP`, `WS_EX_LAYERED\|TRANSPARENT\|NOACTIVATE\|TOOLWINDOW\|TOPMOST`, `SW_SHOWNOACTIVATE`, `MA_NOACTIVATE`. Toggle `TRANSPARENT` off on hover for the control strip. |
| Capture | **WASAPI loopback** | *Easier than macOS* — no permission prompt at all. Per-process capture available on Win 10 2004+. |
| ASR | **sherpa-onnx + Nemotron INT8** | ~650 MB, no GPU required, true streaming with partials and built-in endpointing + Silero VAD. |
| Translation | **llama.cpp GGUF path ports as-is** | MADLAD-on-MLX does not; it would need CTranslate2 or ONNX. Ship the LLM translator on Windows first. |
| Updates | **WinSparkle** | Same lineage as Sparkle. |
| Signing | Authenticode (~$200–400/yr) or Store | |

### Architecture: a core, but a *small* one

Measured, not guessed: 11,328 lines — **6,244 pure UI**, **3,084 Apple-bound
engine glue**, **2,000 Foundation-only**.

Extract a shared core, but draw the line much further in than "capture → ASR →
translation → store". **Capture and inference stay platform-native**, because
each platform's own runtime is strictly better: FluidAudio drives the ANE on
macOS (ONNX Runtime's CoreML EP explicitly does not guarantee ANE execution and
pays CPU↔ANE round-trips), while on Windows being an ONNX consumer is what gets
you free NPU acceleration via Windows ML's brokered runtime.

**In the core:** `SpeechGapDetector`, sentence assembly and the commit rules,
`SegmentCache`, `Retranslate`, the transcript JSONL schema, the SRT/WebVTT/
Markdown exporters, `ModelRegistry`, `DownloadCoordinator`/`FileDownloader`,
and the language tables.

That is the deterministic middle — and it is where the product's quality lives.
`SpeechGapDetector`'s 116 lines encode four designs that failed acoustic replay
before the current one worked. Duplicating that on Windows means re-learning it
by hand.

**Do not write end-to-end golden tests across platforms.** CoreML/ANE and INT8
ONNX will not produce identical tokens. Test the core at the
hypothesis→sentence layer with recorded hypothesis streams as fixtures.

### The strategic question, stated plainly

Windows 11 ships **Live Captions** system-wide and free, with translation.
A Windows sAiity argues against an OS feature. The pitch has to be the parts
Live Captions does not do: 450-language translation, saved searchable
transcripts with fast local search, exports, per-app capture, re-translation. That
is a real pitch — but it is a different one from the Mac version, where the
argument is quality and native feel.

---

## Sequencing

1. **Summary + glossary on Mac** → **1.5**
2. **The acrylic/click-through spike** — half a day, gates everything below
3. **Extract the core** (no behaviour change, Mac stays green throughout)
4. **Windows: capture → sherpa-onnx → overlay** — the prototype
5. **Windows: settings, transcripts, updates, installer** — the long tail
6. **2.0** = both platforms, caption output

Steps 1–2 are weeks. Steps 4–6 are months, and step 6 is where the schedule
actually goes: settings, five languages, transcripts, updates and an installer
are what took this Mac app from working to shippable.

### Version-pinning hazard, noted once

sherpa-onnx and the model export must be pinned **together**, with a
transcription regression check in CI. Older sherpa-onnx versions do not fail
loudly on a mismatched model — they transcribe badly. That is the worst failure
mode there is, and it is documented by someone who shipped it.
