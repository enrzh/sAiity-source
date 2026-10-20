# Syllivra 2.7.0

Published release: https://github.com/enrzh/sAiity/releases/tag/v2.7.0 · Sparkle build 244.

This release keeps the same bundle identifier, settings, downloaded models, transcripts, `saiity://` links and Sparkle update feed, so existing installs update in place. When installing from the DMG, quit the older version and replace its app bundle with Syllivra; keep only one installed copy.

## Highlights

- **Dictation from the shortcut.** Hold the dictation shortcut to speak and release to insert. Settings and setup are redesigned around it. Modifier-only shortcuts are held back briefly so other shortcuts never open the microphone, and the shortcut is only listened for with full key access.
- **Paste into more apps.** Dictation now inserts into browser and Electron text fields, including Chrome's focused text field, and adds a space after dictated text when a word follows.
- **Clearer dictation feedback.** The bubble says when it heard near-silence, silent stretches are skipped before recognition, and cancelled presses log why. Bubble states are translated.
- **More local model options.** Pinned local runtimes and catalogue options for Gemma 4 E2B/E4B cleanup, TranslateGemma 4B translation and the Granite Speech 5.0 470M English recognizer. Existing choices and downloads are kept.
- **Faster and more stable.** Capture starts immediately, dictation delivery work is bounded, warm models are reused, and native work drains before cleanup. The caption bubble hides without the system fade on Stop.
- **Language handling.** Japanese/Korean/Han text stays in coherent phrases, cleanup preserves unhandled languages and guards numbers, dates, currency and negation, translation validates batch slices, and mixed-language transcripts offer a summary-language choice.
- **Reliability.** Captions stay busy until stopping finishes, saved-session retranslation only publishes unchanged input, final translations update all retained rows, and Save confirms beside the action and opens the saved transcript.
- New controls are localized in German, French, Spanish and Japanese.

## Verification

- Notarized and stapled ZIP and drag-to-Applications DMG (Developer ID Application: Xianjie Zhan), Gatekeeper: accepted, Notarized Developer ID.
- Sparkle appcast signed for `Syllivra-2.7.0.zip` (build 244).
- Release GUI self-test passed.
- Quality gate passed: 35 fixture/model/configuration/preview cases on the current en/de corpus (Nemotron segmented decode, live captions at 1120/2240 ms, rules-cleanup release-to-insertion with preview off/on). Model cleanup, Hy-MT2/MADLAD translated runs and the 12-language natural-speech tier are not yet gated.

DMG SHA-256: 71cbb32a91c055f3db8c419694ed68559bb5c6a30825d9cf582c4da9a0403cad

ZIP SHA-256: ae104c82c329c637472d02169b060b2d3da39688f582c0d76d27ec7274020483
