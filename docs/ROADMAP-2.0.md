# sAiity 2.0 — Windows and caption quality

Originally written 2026-08-14 against v1.3.0; Mac feature status updated
2026-10-09 from source. Windows research below is historical planning, not a
current device verification or a shipped Windows release.

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

### 1. Anonymous speaker labels — available, optional

**Captions → More options → Capture → Identify speakers** defaults off and
requires an explicit Speaker identification model download. It adds CPU work
and session-local anonymous labels such as Speaker 1; it does not identify real
people. Confirmed labels appear in history, saved sessions and exports. Multiple
voices in one sentence can share a label row; overlap is marked without
separating overlapping words. Pending audio/evidence are bounded, and overload
or failure disables labels rather than blocking captions. Legacy metadata stays
readable. Real two-person/overlap trials remain a release acceptance requirement.

### 2. Summarise a saved session — shipped

The saved-session reader offers Summarize, Summarize Again and Remove Summary.
It uses the already-installed compatible Gemma cleanup model, downloads nothing,
and waits for shared-model availability. Summaries may omit or invent details;
long input keeps only the latest portion that fits and reports omitted lines.
Spoken lines and SRT/WebVTT remain unchanged; Markdown includes the preface.

### 3. Outgoing captions — proposed, unshipped

Proposed routes are a localhost page consumable as an **OBS browser
source**, and Zoom's third-party closed-caption API (the host generates a URL,
the app POSTs to it). This turns a personal accessibility tool into "caption
this meeting for everyone."

**Remote caption output would send text off the machine.** The consent UI has
to be explicit and per-session, or it breaks the promise the whole app is built
on. Treat Teams as best-effort; its CART ingestion has poor public reliability
reports.

### 4. Shared dictionary — shipped

Names and terms plus explicit Corrections live under More options on both pages.
The bounded local dictionary protects spelling and applies approved whole-phrase
replacements once before cleanup/translation. It does not learn automatically,
perform acoustic biasing or promise fuzzy recognition improvements.

### 5. Realtime captions and translation — shipped

Nemotron offers separate 1120 ms Realtime and 2240 ms Balanced downloads;
Qwen captions remain pause-based. Realtime translation coalesces interim
requests and can slow previews under power, thermal or memory pressure. Final
translations retain priority and only final sentence translations are saved.
These timing choices do not establish measured accuracy or latency on a new Mac.

### Deliberately not in 2.0

| Idea | Why not |
|---|---|
| Real participant names from Zoom/Teams | No supported route. Zoom exposes active speaker on the iOS SDK only, absent on macOS. Would be a scraping hack that breaks. |
| iOS/iPadOS companion | The premise does not exist there: no ScreenCaptureKit equivalent, and the only app-audio route is a ReplayKit extension under a ~50 MB memory cap. These models do not fit. |
| Subtitle burn-in / virtual camera | Burn-in is a video editor's job and SRT/WebVTT already feed every NLE. Virtual camera needs a Camera Extension and a whole new permission story. |
| Multi-target translation (>2–3) | Costs more than intuition suggests — MADLAD's target token goes into the *encoder* input, so each target is a full re-encode, not a cheap decoder swap. Cap at 2–3, sentence mode only. |

---

## Part 2 — Windows

The repository contains an experimental Windows overlay and manually dispatched
build/package workflows. Desktop visual acceptance, complete capture/inference
integration and a supported installer/update release remain unshipped. The
following stack and extraction discussion is a proposal, not current delivery.

### What changed since the last time this was estimated

The ASR swap was assumed to be the schedule risk. It is not.
`nvidia/nemotron-3.5-asr-streaming-0.6b` — the same checkpoint sAiity ships via
FluidAudio's CoreML port — now has first-class ONNX support in **sherpa-onnx**
(k2-fsa, Apache-2.0), including the multilingual variant with the
`prompt_index` language-conditioning input (merged June 2026; re-export shipped
in v1.13.5, 2026-08-11). At least one cross-platform desktop app already ships
it on Windows, CPU-only, with partial results well under a second behind
speech.

The goal is comparable language coverage; identical transcript behaviour across
CoreML and ONNX runtimes is not established by that research.

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

Historical research counted 11,328 lines — **6,244 pure UI**, **3,084 Apple-bound
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

1. **Mac features already available:** shared dictionary, explicit saved-session summaries, realtime caption/translation timing and optional anonymous speaker labels. Complete current-build PRR gates before claiming release readiness.
2. **The acrylic/click-through spike** — the Windows overlay source compiles; the visual check on a Windows 11 desktop is still open and gates everything below
3. **Extract the core** (no behaviour change, Mac stays green throughout)
4. **Windows: capture → sherpa-onnx → overlay** — the prototype
5. **Windows: settings, transcripts, updates, installer** — the long tail
6. **2.0** = both platforms, caption output

Windows steps and outgoing captions have no verified delivery date. Settings,
localizations, transcripts, updates and installer/device acceptance remain real
work, rather than evidence that the prototype is ready to release.

### Version-pinning hazard, noted once

sherpa-onnx and the model export must be pinned **together**, with a
transcription regression check in CI. Older sherpa-onnx versions do not fail
loudly on a mismatched model — they transcribe badly. That is the worst failure
mode there is, and it is documented by someone who shipped it.
