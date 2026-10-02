# Signed-app workflow verification

Use a build without test hooks (`./build-app.sh --no-test-hooks`) for local
checks and the notarized app from the actual release DMG for installation and
update checks. Record the source revision, bundle version/build, macOS version,
hardware, installed models and each outcome. A passing unit suite or `--selftest`
does not establish microphone accuracy, Accessibility paste, installation or
Sparkle updating.

| Workflow | Required observation |
| --- | --- |
| Fresh installation | DMG opens, Applications installation launches, setup offers one recognition download and explains required permissions |
| Permission denial/recovery | Trial explains Microphone or Screen Recording failure; returning from System Settings and retrying succeeds |
| Dictation | Hold/release the configured key; expected complete text lands in an editable field in TextEdit and another ordinary app |
| Focus change / secure field | Switching apps during processing does not paste into the wrong app; a password field refuses insertion |
| Cleanup / translation | Names, numbers and intended meaning survive cleanup; mixed languages remain mixed with translation off and become the target language when on |
| Cancellation | Close setup or cancel while preparing/recording/processing; no later microphone start, result, paste or stale bubble appears |
| Caption clear/restart | Clear the bubble during continuous speech and during a pause; new speech appears without restarting captioning |
| Devices and sleep | Change input devices and sleep/wake; capture resumes or gives a recovery action rather than silently stalling |
| Appearance and displays | All presets work in light/dark, increased contrast and reduced motion; bubbles stay visible after disconnecting an external display |
| Keyboard and accessibility | Tab/Shift-Tab, Space, Escape, standard editing shortcuts and VoiceOver reach trial and settings controls |
| Upgrade | Sparkle installs the offered notarized version; models, shortcuts, style and saved transcripts survive |

At minimum verify macOS 26 and 27 on Apple Silicon, including the M4 MacBook Air
that previously reproduced crashes. Mark unavailable combinations **not tested**.
Keep recordings and transcripts outside Git; diagnostics should contain timings
and error summaries rather than conversation content.

Automatic coverage: CI runs the release Swift tests, quality-gate self-checks,
builds without test hooks, verifies native resources/signatures and runs the
signed bundle's `--selftest`. That smoke test exercises bubble presets, caption
clear/new content, dictation waveform/result/reset and all setup trial layouts.
`scripts/release.sh` additionally requires current, clean-source real-model
quality reports and a successful GUI smoke test before creating the release tag.
